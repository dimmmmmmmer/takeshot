@preconcurrency import CoreImage
import Foundation

/// The assist filter chains: the zebra mask cache and the stack that puts the
/// exposure tools over a frame. The palettes the stack remaps through live in
/// `AssistPalettes`, the framelines drawn over the result in `AssistGuides`.
///
/// A namespace of its own rather than an extension on `MetalPreviewLayer`,
/// where this used to live. That placement WAS owner item 7: a chain owned by
/// one preview layer runs once per SURFACE, so the aids reached the windows
/// that mount a layer and nothing else — not the hardware playout, not the
/// phone multiview. It runs once per FRAME now, in the display stage
/// (`AssistStage`), and every mirror of that frame carries it.
enum AssistFilters {
    /// Grayscale in BT.709 weights — the base for the luma-driven tools.
    static func grayscale(_ image: CIImage) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            "inputGVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            "inputBVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
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
        let data = lumaCube(size: 32) { v in
            let on = v >= Double(key) / 100 ? 1.0 : 0
            return BandColor(on, on, on)
        }
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
    static func applied(_ source: CIImage, assist: ViewAssist) -> CIImage {
        var out = source
        switch assist.colorTool {
        case .off:
            break
        case .falseColor:
            out = remapped(source, through: falseColorCube)
        case .elZone:
            out = remapped(source, through: elZoneCube)
        }
        if assist.zebraOn {
            out = zebraStriped(out, source: source,
                               threshold: assist.zebraThreshold)
        }
        if assist.peakingOn {
            out = peakingEdges(over: out, source: source,
                               intensity: assist.peakingIntensity,
                               color: assist.peakingColor)
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

    /// Focus-peaking edges, tinted the operator's color, screened over whatever
    /// is already there.
    ///
    /// The edge detector is a convolution, and CoreImage answers samples taken
    /// past a finite image with transparent black — which reads as the
    /// strongest edge in the frame and painted a bright line right along the
    /// picture's border. On a letterboxed player that line sits against the
    /// black bar and looks exactly like peaking highlighting the letterbox.
    /// `clampedToExtent` repeats the border pixels outward instead (no edge
    /// where the frame simply ends), and the pass is cropped back to the video
    /// rect so it cannot reach outside the picture at all.
    private static func peakingEdges(over image: CIImage, source: CIImage,
                                     intensity: Double,
                                     color: ViewAssist.PeakingColor) -> CIImage {
        // the matrix routes the grayscale edge response into the tint's
        // channels; 2.4 is the gain the fixed red overlay shipped with
        let tint = color.components
        let gain = 2.4
        let edges = grayscale(source)
            .clampedToExtent()
            .applyingFilter("CIEdges", parameters: [
                "inputIntensity": intensity,
            ])
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: gain * tint.red, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: gain * tint.green, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: gain * tint.blue, y: 0, z: 0, w: 0),
            ])
            .cropped(to: source.extent)
        return edges.applyingFilter("CIScreenBlendMode", parameters: [
            kCIInputBackgroundImageKey: image,
        ])
    }
}
