import CoreImage
import os.log

/// Operator display aids applied inside the preview render (identically on
/// every surface: live, playback, RAW, fullscreen, external).
public struct ViewAssist: Equatable, Sendable {
    /// Color remap tools are mutually exclusive; zebra/peaking stack on top.
    public enum ColorTool: String, CaseIterable, Sendable {
        case off
        case falseColor
        case elZone
    }

    public var colorTool: ColorTool = .off
    public var zebraOn = false
    /// Zebra trigger level, 0.70…1.0 of full scale.
    public var zebraThreshold: Double = 0.95
    public var peakingOn = false
    /// Edge gain for the peaking overlay.
    public var peakingIntensity: Double = 12
    /// Anamorphic desqueeze factor (1 = spherical).
    public var desqueeze: Double = 1
    /// Punch-in magnification (1 = off).
    public var punchIn: Double = 1
    /// Pan while punched in, in image-fraction units (0 = centered).
    public var panX: Double = 0
    public var panY: Double = 0

    public var anyToolActive: Bool {
        colorTool != .off || zebraOn || peakingOn
    }

    public init() {}
}
import CoreVideo
import Metal
import QuartzCore

/// Video preview drawn through the ordinary graphics compositor (CAMetalLayer
/// + CoreImage), the way every image in every app is shown: the layer declares
/// its colorspace (the same ICC Rec.709 space the ProRes decoder tags frames
/// with) and WindowServer converts it to the display exactly as it does for
/// Preview/Finder/browsers.
///
/// The video display path (AVSampleBufferDisplayLayer) is avoided deliberately:
/// when such a layer is composited (rounded corners, overlays) instead of
/// getting the hardware video plane, video-range codes reach the screen
/// unexpanded — washed blacks that no buffer format or tagging fixes (BGRA,
/// 2vuy and 420v all measured identically wrong).
public final class MetalPreviewLayer: CAMetalLayer {
    private var ciContext: CIContext?
    private let renderLock = NSLock()
    private var lastBuffer: CVPixelBuffer?
    /// Aspect-fit letterbox color (over the player backdrop).
    public var letterboxColor = CIColor(red: 0, green: 0, blue: 0)
    /// When set, the center pixel of every ~50th presented frame goes to the
    /// unified log — parity debugging between surfaces (rec vs playback).
    public var debugTag: String?
    private var presentCount = 0
    /// Display aids (read under renderLock; use setAssist from any thread).
    private var assist = ViewAssist()

    public func setAssist(_ newValue: ViewAssist) {
        renderLock.lock()
        let changed = assist != newValue
        assist = newValue
        renderLock.unlock()
        if changed { redraw() }
    }

    // MARK: - assist filter chains (static, shared across layers)

    /// Grayscale in BT.709 weights — the base for the luma-driven tools.
    private static func grayscale(_ image: CIImage) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            "inputGVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            "inputBVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
    }

    /// Exposure bands on gamma-encoded code values (ARRI-style palette).
    nonisolated(unsafe) private static let falseColorCube: Data = {
        let size = 64
        var rgba = [Float]()
        rgba.reserveCapacity(size * size * size * 4)
        func band(_ v: Double) -> (Double, Double, Double) {
            switch v {
            case ..<0.025: return (0.58, 0.20, 0.75)  // purple — crushed
            case ..<0.08: return (0.16, 0.34, 0.90)   // blue — deep shadow
            case ..<0.36: return (v, v, v)            // gray ramp
            case ..<0.44: return (0.15, 0.75, 0.25)   // green — 18% gray
            case ..<0.52: return (v, v, v)
            case ..<0.58: return (0.95, 0.60, 0.70)   // pink — skin highlight
            case ..<0.92: return (v, v, v)
            case ..<0.97: return (0.98, 0.90, 0.20)   // yellow — near clip
            default: return (0.95, 0.15, 0.10)        // red — clipped
            }
        }
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    // input is grayscale (r=g=b on the diagonal); using luma
                    // keeps off-axis values sane anyway
                    let v = 0.2126 * Double(r) + 0.7152 * Double(g)
                        + 0.0722 * Double(b)
                    let (red, green, blue) = band(v / Double(size - 1))
                    rgba += [Float(red), Float(green), Float(blue), 1]
                }
            }
        }
        return rgba.withUnsafeBufferPointer { Data(buffer: $0) }
    }()

    /// EL Zone-style stops around 18% gray: display luma is linearized with
    /// the inverse BT.709 OETF, zones colored per stop (approximation of the
    /// Ed Lachman scale).
    nonisolated(unsafe) private static let elZoneCube: Data = {
        let size = 64
        var rgba = [Float]()
        rgba.reserveCapacity(size * size * size * 4)
        func zoneColor(_ stop: Double) -> (Double, Double, Double) {
            switch stop.rounded() {
            case ..<(-5): return (0.04, 0.04, 0.04)   // ≤ -6: black
            case -5: return (0.45, 0.15, 0.65)        // purple
            case -4: return (0.15, 0.25, 0.90)        // blue
            case -3: return (0.10, 0.60, 0.70)        // teal
            case -2: return (0.15, 0.65, 0.25)        // green
            case -1: return (0.32, 0.32, 0.32)        // dark gray
            case 0: return (0.50, 0.50, 0.50)         // 18% — mid gray
            case 1: return (0.68, 0.68, 0.68)         // light gray
            case 2: return (0.95, 0.60, 0.65)         // pink
            case 3: return (0.95, 0.55, 0.15)         // orange
            case 4: return (0.98, 0.72, 0.30)         // light orange
            case 5: return (0.98, 0.92, 0.25)         // yellow
            default: return (1, 1, 1)                 // ≥ +6: white
            }
        }
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
                    let (red, green, blue) = zoneColor(stop)
                    rgba += [Float(red), Float(green), Float(blue), 1]
                }
            }
        }
        return rgba.withUnsafeBufferPointer { Data(buffer: $0) }
    }()

    /// White where luma ≥ threshold — the zebra mask (cached per threshold).
    nonisolated(unsafe) private static var zebraCubes: [Int: Data] = [:]
    private static let zebraCubeLock = NSLock()

    private static func zebraMaskCube(threshold: Double) -> Data {
        let key = Int((threshold * 100).rounded())
        zebraCubeLock.lock()
        defer { zebraCubeLock.unlock() }
        if let cached = zebraCubes[key] { return cached }
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
        return data
    }

    /// Tools stack: color remap first, then zebra stripes, then peaking edges
    /// (masks always come from the SOURCE image, so exposure reads true even
    /// over a false-color remap). Result is cropped to the source extent —
    /// filter spill outside the frame painted the letterbox red.
    private func applyAssist(_ source: CIImage, assist: ViewAssist) -> CIImage {
        var out = source
        switch assist.colorTool {
        case .off:
            break
        case .falseColor:
            out = Self.grayscale(source).applyingFilter(
                "CIColorCube", parameters: [
                    "inputCubeDimension": 64,
                    "inputCubeData": Self.falseColorCube,
                ])
        case .elZone:
            out = Self.grayscale(source).applyingFilter(
                "CIColorCube", parameters: [
                    "inputCubeDimension": 64,
                    "inputCubeData": Self.elZoneCube,
                ])
        }
        if assist.zebraOn {
            let mask = Self.grayscale(source).applyingFilter(
                "CIColorCube", parameters: [
                    "inputCubeDimension": 32,
                    "inputCubeData": Self.zebraMaskCube(
                        threshold: assist.zebraThreshold),
                ])
            if let stripes = CIFilter(name: "CIStripesGenerator", parameters: [
                "inputColor0": CIColor(red: 1, green: 1, blue: 1),
                "inputColor1": CIColor(red: 0, green: 0, blue: 0),
                "inputWidth": 4,
                "inputSharpness": 1,
            ])?.outputImage?
                .transformed(by: CGAffineTransform(rotationAngle: .pi / 4))
                .cropped(to: source.extent) {
                let striped = stripes.applyingFilter(
                    "CIMultiplyCompositing", parameters: [
                        kCIInputBackgroundImageKey: mask,
                    ])
                out = CIImage(color: CIColor(red: 1, green: 1, blue: 1))
                    .cropped(to: source.extent)
                    .applyingFilter("CIBlendWithMask", parameters: [
                        kCIInputBackgroundImageKey: out,
                        kCIInputMaskImageKey: striped,
                    ])
            }
        }
        if assist.peakingOn {
            let edges = Self.grayscale(source)
                .applyingFilter("CIEdges", parameters: [
                    "inputIntensity": assist.peakingIntensity,
                ])
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 2.4, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                ])
            out = edges.applyingFilter("CIScreenBlendMode", parameters: [
                kCIInputBackgroundImageKey: out,
            ])
        }
        return out.cropped(to: source.extent)
    }

    public override init() {
        super.init()
        commonInit()
    }

    public override init(layer: Any) {
        super.init(layer: layer)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        device = MTLCreateSystemDefaultDevice()
        pixelFormat = .bgra8Unorm
        framebufferOnly = false
        isOpaque = true
        // the same "HDTV" ICC colorspace the ProRes decoder attaches to frames
        let attachments = [
            kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kCVImageBufferTransferFunctionKey: kCVImageBufferTransferFunction_ITU_R_709_2,
            kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        ] as CFDictionary
        colorspace = CVImageBufferCreateColorSpaceFromAttachments(attachments)?
            .takeRetainedValue()
            ?? CGColorSpace(name: CGColorSpace.itur_709)
        if let device {
            ciContext = CIContext(mtlDevice: device,
                                  options: [.cacheIntermediates: false])
        }
    }

    /// Re-render the last frame (window resized while paused/no signal —
    /// otherwise the old drawable stretches to the new bounds).
    public func redraw() {
        renderLock.lock()
        let buffer = lastBuffer // strong read under the lock: present() swaps
        renderLock.unlock()     // it concurrently on the producer queue
        guard let buffer else { return }
        present(buffer)
    }

    /// Blank the layer (signal loss) instead of freezing the last frame.
    public func clearToBlack() {
        renderLock.lock()
        defer { renderLock.unlock() }
        lastBuffer = nil
        guard let ciContext else { return }
        let size = drawableSize
        guard size.width > 1, size.height > 1,
              let drawable = nextDrawable() else { return }
        let bounds = CGRect(origin: .zero, size: size)
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0))
            .cropped(to: bounds)
        let destination = CIRenderDestination(mtlTexture: drawable.texture,
                                              commandBuffer: nil)
        destination.colorSpace = nil
        if let task = try? ciContext.startTask(toRender: black, to: destination) {
            _ = try? task.waitUntilCompleted()
        }
        drawable.present()
    }

    /// Draw a frame (any CoreImage-supported pixel format), aspect-fit.
    /// Safe to call from the producer's queue; pixel values are passed through
    /// unmanaged — the layer's `colorspace` tells the compositor what they mean.
    public func present(_ pixelBuffer: CVPixelBuffer) {
        guard let ciContext else { return }
        renderLock.lock()
        defer { renderLock.unlock() }
        lastBuffer = pixelBuffer
        if let debugTag {
            presentCount += 1
            if presentCount % 50 == 1,
               CVPixelBufferGetPixelFormatType(pixelBuffer)
                   == kCVPixelFormatType_32BGRA {
                CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
                if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                    let w = CVPixelBufferGetWidth(pixelBuffer)
                    let h = CVPixelBufferGetHeight(pixelBuffer)
                    let bpr = CVPixelBufferGetBytesPerRow(pixelBuffer)
                    let bytes = base.assumingMemoryBound(to: UInt8.self)
                    let p = bytes + (h / 2) * bpr + (w / 2) * 4
                    // 16x16 grid mean: catches a global shift in any tonal
                    // zone, not just whatever sits under the center pixel
                    var sumR = 0, sumG = 0, sumB = 0
                    for gy in 0..<16 {
                        let row = bytes + ((gy * 2 + 1) * h / 32) * bpr
                        for gx in 0..<16 {
                            let q = row + ((gx * 2 + 1) * w / 32) * 4
                            sumB += Int(q[0]); sumG += Int(q[1]); sumR += Int(q[2])
                        }
                    }
                    os_log("probe %{public}s %dx%d center=(%d,%d,%d) mean=(%d,%d,%d)",
                           log: CapturePipeline.levelsLog, type: .default,
                           debugTag, w, h, p[2], p[1], p[0],
                           sumR / 256, sumG / 256, sumB / 256)
                }
                CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
            }
        }
        let size = drawableSize
        guard size.width > 1, size.height > 1 else { return }
        guard let drawable = nextDrawable() else { return }
        var image = CIImage(cvPixelBuffer: pixelBuffer,
                            options: [.colorSpace: NSNull()])
        let currentAssist = assist
        if currentAssist.anyToolActive {
            image = applyAssist(image, assist: currentAssist)
        }
        if currentAssist.desqueeze != 1 {
            image = image.transformed(by: CGAffineTransform(
                scaleX: currentAssist.desqueeze, y: 1))
        }
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return }
        var scale = min(size.width / extent.width, size.height / extent.height)
        if currentAssist.punchIn > 1 {
            scale *= currentAssist.punchIn // magnification with pan below
        }
        // integral-pixel placement: fractional offsets shift live vs playback
        // by a visible pixel in the compare modes (wipe/blend/side-by-side)
        var tx = ((size.width - extent.width * scale) / 2).rounded(.down)
        var ty = ((size.height - extent.height * scale) / 2).rounded(.down)
        if currentAssist.punchIn > 1 {
            // pan in image fractions; SwiftUI's y grows down, CI's grows up
            tx -= (currentAssist.panX * extent.width * scale).rounded(.down)
            ty += (currentAssist.panY * extent.height * scale).rounded(.down)
        }
        image = image
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale)
                .concatenating(CGAffineTransform(translationX: tx, y: ty)))
        let bounds = CGRect(origin: .zero, size: size)
        let composed = image.composited(over:
            CIImage(color: letterboxColor).cropped(to: bounds))
        // color management off on both ends: code values pass through unchanged,
        // and the layer's `colorspace` alone tells the compositor what they mean
        let destination = CIRenderDestination(mtlTexture: drawable.texture,
                                              commandBuffer: nil)
        destination.colorSpace = nil
        guard let task = try? ciContext.startTask(toRender: composed,
                                                  to: destination) else { return }
        _ = try? task.waitUntilCompleted()
        drawable.present()
    }
}
