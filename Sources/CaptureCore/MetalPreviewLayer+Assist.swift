@preconcurrency import CoreImage
import Foundation

/// The assist filter chains: the exposure palettes, the zebra mask cache and
/// the stack that puts them over a frame. Static and shared across every
/// layer — the cubes are built once for the process.
///
/// Split out of MetalPreviewLayer, whose body had grown past 380 lines.
extension MetalPreviewLayer {
    // MARK: - assist filter chains (static, shared across layers)

    /// One entry of an exposure palette. A named type rather than a triple:
    /// three unlabelled Doubles read the same whatever order they are in.
    struct BandColor {
        let red: Double
        let green: Double
        let blue: Double

        init(_ red: Double, _ green: Double, _ blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }
    }

    /// Grayscale in BT.709 weights — the base for the luma-driven tools.
    static func grayscale(_ image: CIImage) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            "inputGVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            "inputBVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
    }

    /// Exposure bands on gamma-encoded code values (ARRI-style palette).
    static let falseColorCube: Data = {
        let size = 64
        var rgba = [Float]()
        rgba.reserveCapacity(size * size * size * 4)
        func band(_ v: Double) -> BandColor {
            switch v {
            case ..<0.025: return BandColor(0.58, 0.20, 0.75)  // purple — crushed
            case ..<0.08: return BandColor(0.16, 0.34, 0.90)   // blue — deep shadow
            case ..<0.36: return BandColor(v, v, v)            // gray ramp
            case ..<0.44: return BandColor(0.15, 0.75, 0.25)   // green — 18% gray
            case ..<0.52: return BandColor(v, v, v)
            case ..<0.58: return BandColor(0.95, 0.60, 0.70)   // pink — skin highlight
            case ..<0.92: return BandColor(v, v, v)
            case ..<0.97: return BandColor(0.98, 0.90, 0.20)   // yellow — near clip
            default: return BandColor(0.95, 0.15, 0.10)        // red — clipped
            }
        }
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    // input is grayscale (r=g=b on the diagonal); using luma
                    // keeps off-axis values sane anyway
                    let v = 0.2126 * Double(r) + 0.7152 * Double(g)
                        + 0.0722 * Double(b)
                    let color = band(v / Double(size - 1))
                    rgba += [Float(color.red), Float(color.green), Float(color.blue), 1]
                }
            }
        }
        return rgba.withUnsafeBufferPointer { Data(buffer: $0) }
    }()

    /// EL Zone-style stops around 18% gray: display luma is linearized with
    /// the inverse BT.709 OETF, zones colored per stop (approximation of the
    /// Ed Lachman scale).
    static let elZoneCube: Data = {
        let size = 64
        var rgba = [Float]()
        rgba.reserveCapacity(size * size * size * 4)
        func linear(_ v: Double) -> Double {
            // inverse BT.709 OETF
            v < 0.081 ? v / 4.5 : pow((v + 0.099) / 1.099, 1 / 0.45)
        }
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let v = (0.2126 * Double(r) + 0.7152 * Double(g)
                        + 0.0722 * Double(b)) / Double(size - 1)
                    let lin = max(1e-6, linear(v))
                    let stop = log2(lin / 0.18)
                    let color = MetalPreviewLayer.zoneColor(stop)
                    rgba += [Float(color.red), Float(color.green), Float(color.blue), 1]
                }
            }
        }
        return rgba.withUnsafeBufferPointer { Data(buffer: $0) }
    }()

    /// The EL Zone scale as a ramp indexed by whole stops from 18% gray, with
    /// the two open ends on the end entries. A table rather than a 13-case
    /// switch: the same values, in the order a reader checks them against the
    /// scale.
    static let elZoneRamp: [BandColor] = [
        BandColor(0.04, 0.04, 0.04),   // ≤ -6: black
        BandColor(0.45, 0.15, 0.65),   // -5: purple
        BandColor(0.15, 0.25, 0.90),   // -4: blue
        BandColor(0.10, 0.60, 0.70),   // -3: teal
        BandColor(0.15, 0.65, 0.25),   // -2: green
        BandColor(0.32, 0.32, 0.32),   // -1: dark gray
        BandColor(0.50, 0.50, 0.50),   // 0: 18% — mid gray
        BandColor(0.68, 0.68, 0.68),   // +1: light gray
        BandColor(0.95, 0.60, 0.65),   // +2: pink
        BandColor(0.95, 0.55, 0.15),   // +3: orange
        BandColor(0.98, 0.72, 0.30),   // +4: light orange
        BandColor(0.98, 0.92, 0.25),   // +5: yellow
        BandColor(1, 1, 1),            // ≥ +6: white
    ]

    static func zoneColor(_ stop: Double) -> BandColor {
        // rounding first makes the ends whole stops too, so clamping to ±6
        // lands "≤ -6" and "≥ +6" on the ramp's first and last entries
        let whole = min(6, max(-6, stop.rounded()))
        return elZoneRamp[Int(whole) + 6]
    }

    /// White where luma ≥ threshold — the zebra mask (cached per threshold).
    /// Each cube is 512 KB and the slider offers 31 distinct thresholds, so the
    /// cache is capped: one sweep of the slider would otherwise pin ~16 MB for
    /// the rest of the session.
    nonisolated(unsafe) private static var zebraCubes: [Int: Data] = [:]
    nonisolated(unsafe) private static var zebraCubeOrder: [Int] = []
    private static let zebraCubeLock = NSLock()
    private static let zebraCubeLimit = 4

    private static func zebraMaskCube(threshold: Double) -> Data {
        let key = Int((threshold * 100).rounded())
        zebraCubeLock.lock()
        defer { zebraCubeLock.unlock() }
        if let cached = zebraCubes[key] {
            zebraCubeOrder.removeAll { $0 == key }
            zebraCubeOrder.append(key)
            return cached
        }
        let size = 32
        var rgba = [Float]()
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let v = (0.2126 * Double(r) + 0.7152 * Double(g)
                        + 0.0722 * Double(b)) / Double(size - 1)
                    let on: Float = v >= Double(key) / 100 ? 1 : 0
                    rgba += [on, on, on, 1]
                }
            }
        }
        let data = rgba.withUnsafeBufferPointer { Data(buffer: $0) }
        zebraCubes[key] = data
        zebraCubeOrder.append(key)
        while zebraCubeOrder.count > zebraCubeLimit {
            zebraCubes.removeValue(forKey: zebraCubeOrder.removeFirst())
        }
        return data
    }

    /// Tools stack: color remap first, then zebra stripes, then peaking edges
    /// (masks always come from the SOURCE image, so exposure reads true even
    /// over a false-color remap). Result is cropped to the source extent —
    /// filter spill outside the frame painted the letterbox red.
    func applyAssist(_ source: CIImage, assist: ViewAssist) -> CIImage {
        var out = source
        switch assist.colorTool {
        case .off:
            break
        case .falseColor:
            out = Self.remapped(source, through: Self.falseColorCube)
        case .elZone:
            out = Self.remapped(source, through: Self.elZoneCube)
        }
        if assist.zebraOn {
            out = Self.zebraStriped(out, source: source,
                                    threshold: assist.zebraThreshold)
        }
        if assist.peakingOn {
            out = Self.peakingEdges(over: out, source: source,
                                    intensity: assist.peakingIntensity)
        }
        return out.cropped(to: source.extent)
    }

    /// Luma of the source through one of the 64³ exposure palettes.
    private static func remapped(_ source: CIImage, through cube: Data) -> CIImage {
        grayscale(source).applyingFilter("CIColorCube", parameters: [
            "inputCubeDimension": 64,
            "inputCubeData": cube,
        ])
    }

    /// Diagonal white stripes wherever the SOURCE is at or above the zebra
    /// threshold. `image` (which may already carry a remap) shows through
    /// everywhere else; if the stripe generator is unavailable it is returned
    /// untouched.
    private static func zebraStriped(_ image: CIImage, source: CIImage,
                                     threshold: Double) -> CIImage {
        let mask = grayscale(source).applyingFilter(
            "CIColorCube", parameters: [
                "inputCubeDimension": 32,
                "inputCubeData": zebraMaskCube(threshold: threshold),
            ])
        guard let stripes = CIFilter(name: "CIStripesGenerator", parameters: [
            "inputColor0": CIColor(red: 1, green: 1, blue: 1),
            "inputColor1": CIColor(red: 0, green: 0, blue: 0),
            "inputWidth": 4,
            "inputSharpness": 1,
        ])?.outputImage?
            .transformed(by: CGAffineTransform(rotationAngle: .pi / 4))
            .cropped(to: source.extent) else { return image }
        let striped = stripes.applyingFilter(
            "CIMultiplyCompositing", parameters: [
                kCIInputBackgroundImageKey: mask,
            ])
        return CIImage(color: CIColor(red: 1, green: 1, blue: 1))
            .cropped(to: source.extent)
            .applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: image,
                kCIInputMaskImageKey: striped,
            ])
    }

    /// Red focus-peaking edges screened over whatever is already there.
    private static func peakingEdges(over image: CIImage, source: CIImage,
                                     intensity: Double) -> CIImage {
        let edges = grayscale(source)
            .applyingFilter("CIEdges", parameters: [
                "inputIntensity": intensity,
            ])
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 2.4, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            ])
        return edges.applyingFilter("CIScreenBlendMode", parameters: [
            kCIInputBackgroundImageKey: image,
        ])
    }
}
