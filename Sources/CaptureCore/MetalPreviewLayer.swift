import CoreImage
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
        guard let buffer = lastBuffer else { return }
        present(buffer)
    }

    /// Draw a frame (any CoreImage-supported pixel format), aspect-fit.
    /// Safe to call from the producer's queue; pixel values are passed through
    /// unmanaged — the layer's `colorspace` tells the compositor what they mean.
    public func present(_ pixelBuffer: CVPixelBuffer) {
        guard let ciContext else { return }
        renderLock.lock()
        defer { renderLock.unlock() }
        lastBuffer = pixelBuffer
        let size = drawableSize
        guard size.width > 1, size.height > 1 else { return }
        guard let drawable = nextDrawable() else { return }
        var image = CIImage(cvPixelBuffer: pixelBuffer,
                            options: [.colorSpace: NSNull()])
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return }
        let scale = min(size.width / extent.width, size.height / extent.height)
        // integral-pixel placement: fractional offsets shift live vs playback
        // by a visible pixel in the compare modes (wipe/blend/side-by-side)
        let tx = ((size.width - extent.width * scale) / 2).rounded(.down)
        let ty = ((size.height - extent.height * scale) / 2).rounded(.down)
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
