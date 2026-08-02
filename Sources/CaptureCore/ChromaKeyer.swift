@preconcurrency import CoreImage
@preconcurrency import CoreVideo
import Foundation

/// The CoreImage stage that puts a chroma key on a display frame: one cube
/// lookup that turns the screen into alpha and despills what is left, and one
/// composite that puts the chosen background behind it.
///
/// Two passes and no more, because this runs on every displayed frame. The
/// cube is where all the arithmetic went (see `ChromaKey.cubeData`) — it is
/// rebuilt only when the operator moves a control, and the GPU then walks it
/// per pixel for the price of a texture lookup.
///
/// @unchecked Sendable: every method here is confined to ONE queue — the
/// pipeline's display queue, which owns the whole display stage. Nothing else
/// may call in. The pipeline states the same contract at the call site.
public final class ChromaKeyer: @unchecked Sendable {
    private let context: CIContext
    private let pool = PixelBufferPool()
    /// The last cube built, and the parameters it was built from.
    private var cachedCubeKey: ChromaKey.CubeKey?
    private var cachedCube: Data?
    /// The fitted plate is invariant per (buffer, frame size) — rebuilt only
    /// when the operator loads another one or the signal changes shape.
    private struct FittedPlate {
        let source: CVPixelBuffer
        let extent: CGRect
        let image: CIImage
    }

    /// The operator's plate, and the fitted CIImage of it for one frame size.
    private var plate: CVPixelBuffer?
    private var fittedPlate: FittedPlate?

    public init() {
        // Its own context rather than the pipeline's: that one belongs to the
        // capture queue (levels, LUT, the compare composite) and this stage
        // runs on the display queue. A context holds caches sized for the work
        // it has seen, and these two see different work.
        context = CIContext(options: [.cacheIntermediates: false])
    }

    /// The plate that shows through the key with `background == .image`.
    /// Display-queue only, like everything else here.
    public func setBackgroundImage(_ buffer: CVPixelBuffer?) {
        plate = buffer
        fittedPlate = nil
    }

    /// The frame with the key applied, or nil when there is nothing to do or
    /// the render failed — in both cases the caller shows the ORIGINAL frame.
    /// A failed render must never hand uninitialized pool memory to a surface.
    public func keyed(_ pixelBuffer: CVPixelBuffer,
                      key: ChromaKey) -> CVPixelBuffer? {
        guard key.isOn else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0,
              let out = pool.buffer(width: width, height: height) else { return nil }
        // raw code values on both ends, like every other stage in the display
        // path: the cube is defined on gamma-encoded codes, and a managed
        // render here would key on values nobody in this app ever sees
        let source = CIImage(cvPixelBuffer: pixelBuffer,
                             options: [.colorSpace: NSNull()])
        let composed = composited(source, key: key)
        let destination = CIRenderDestination(pixelBuffer: out)
        destination.colorSpace = nil
        guard let task = try? context.startTask(toRender: composed,
                                                to: destination),
              (try? task.waitUntilCompleted()) != nil else { return nil }
        return out
    }

    /// Keyed foreground over the chosen background, cropped to the frame —
    /// filter spill outside the extent is what paints a border on the
    /// letterbox (the peaking overlay learned that one the hard way).
    private func composited(_ source: CIImage, key: ChromaKey) -> CIImage {
        let extent = source.extent
        let matteOnly = key.background == .matte
        let keyed = source.applyingFilter("CIColorCube", parameters: [
            "inputCubeDimension": ChromaKey.cubeDimension,
            "inputCubeData": cube(for: key, matteOnly: matteOnly),
        ])
        // the matte IS the picture in that mode: black and white, nothing behind
        guard !matteOnly else { return keyed.cropped(to: extent) }
        return keyed
            .applyingFilter("CISourceOverCompositing", parameters: [
                kCIInputBackgroundImageKey: background(for: key, extent: extent),
            ])
            .cropped(to: extent)
    }

    /// The lookup table, rebuilt only when the controls that define it moved.
    private func cube(for key: ChromaKey, matteOnly: Bool) -> Data {
        let wanted = key.cubeKey
        if let cachedCube, cachedCubeKey == wanted { return cachedCube }
        let data = key.cubeData(matteOnly: matteOnly)
        cachedCubeKey = wanted
        cachedCube = data
        return data
    }

    /// What goes behind the actor.
    private func background(for key: ChromaKey, extent: CGRect) -> CIImage {
        switch key.background {
        case .color, .matte:
            return CIImage(color: Self.passthrough(key.backgroundColor))
                .cropped(to: extent)
        case .checkerboard:
            return Self.checkerboard(extent: extent)
        case .image:
            // no plate chosen yet: the checkerboard, not a black hole where the
            // picture was — "I loaded nothing" and "my key ate the frame" have
            // to look different
            guard let plate else { return Self.checkerboard(extent: extent) }
            if let cache = fittedPlate, cache.source === plate,
               cache.extent == extent {
                return cache.image
            }
            let fitted = CompareCompositor.fitted(
                CIImage(cvPixelBuffer: plate, options: [.colorSpace: NSNull()]),
                into: extent)
            fittedPlate = FittedPlate(source: plate, extent: extent, image: fitted)
            return fitted
        }
    }

    /// The "is my key clean" background: two grays, squares sized off the frame
    /// so the pattern reads the same on an HD and a UHD signal.
    private static func checkerboard(extent: CGRect) -> CIImage {
        let square = max(8, (extent.width / 24).rounded())
        guard let generator = CIFilter(name: "CICheckerboardGenerator",
                                       parameters: [
            "inputColor0": passthrough(ChromaKey.RGB(0.30, 0.30, 0.30)),
            "inputColor1": passthrough(ChromaKey.RGB(0.55, 0.55, 0.55)),
            "inputWidth": square,
            "inputSharpness": 1,
        ]), let image = generator.outputImage else {
            return CIImage(color: passthrough(ChromaKey.RGB(0.4, 0.4, 0.4)))
                .cropped(to: extent)
        }
        return image.cropped(to: extent)
    }

    /// A color whose components reach the frame as the numbers they were
    /// written as.
    ///
    /// `CIColor(red:green:blue:)` states its components in sRGB and CoreImage
    /// converts them into its linear working space on the way into the graph.
    /// On a color-managed render that is invisible; this display path is
    /// deliberately unmanaged end to end, so the conversion survives all the
    /// way to the screen and a 30% grey arrives as code 19. Declaring the
    /// components in the working space itself makes that conversion an
    /// identity, which is what lets the operator's background color be the
    /// color they picked (pinned by `theSolidBackgroundIsTheColorItWasGiven`).
    static func passthrough(_ color: ChromaKey.RGB) -> CIColor {
        if let space = CGColorSpace(name: CGColorSpace.linearSRGB),
           let exact = CIColor(red: color.red, green: color.green,
                               blue: color.blue, colorSpace: space) {
            return exact
        }
        return CIColor(red: color.red, green: color.green, blue: color.blue)
    }
}
