@preconcurrency import CoreImage
@preconcurrency import CoreVideo
import Metal
@preconcurrency import QuartzCore

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
/// @unchecked Sendable: the layer is handed between the main thread (mounts,
/// settings) and producer queues (frames). Everything shared is behind
/// renderLock (the render itself) or stateLock (the values main hands over).
///
/// The draw path lives in `+Render`, the display aids in `+Assist`. The state
/// below is internal rather than private for exactly that reason — never wider
/// than the module.
public final class MetalPreviewLayer: CAMetalLayer, @unchecked Sendable {
    var ciContext: CIContext?
    let renderLock = NSLock()
    var lastBuffer: CVPixelBuffer?
    /// Guards the handful of values the main thread hands to the renderer.
    /// Deliberately NOT renderLock: that one is held across GPU work, and a
    /// settings change must never wait on a parked nextDrawable().
    let stateLock = NSLock()
    var storedLetterboxColor = CIColor(red: 0, green: 0, blue: 0)
    var pendingDrawableSize: CGSize?
    /// Latest frame waiting to be drawn, and whether a draw is already queued.
    var pendingPresent: CVPixelBuffer?
    var presentScheduled = false
    /// Where UI-triggered re-renders run, so they never block the main thread.
    let redrawQueue = DispatchQueue(label: "takeshot.preview-redraw",
                                    qos: .userInitiated)
    /// Aspect-fit letterbox color (over the player backdrop). Safe to set from
    /// any thread while a producer queue is presenting.
    public var letterboxColor: CIColor {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return storedLetterboxColor
        }
        set {
            stateLock.lock()
            storedLetterboxColor = newValue
            stateLock.unlock()
        }
    }

    /// Resize the drawable from the view's layout pass. The renderer applies it
    /// itself: assigning `drawableSize` reallocates CAMetalLayer's drawable pool,
    /// and doing that while a producer queue sits in `nextDrawable()` either
    /// renders one frame at the wrong geometry or wedges the display queue.
    public func setDrawableSize(_ size: CGSize) {
        stateLock.lock()
        let changed = pendingDrawableSize != size && drawableSize != size
        if changed { pendingDrawableSize = size }
        stateLock.unlock()
        // paused playback / no signal: no new frame will arrive to fill the
        // resized drawable — redraw the last one right away
        if changed { redraw() }
    }

    /// When set, the center pixel of every ~50th presented frame goes to the
    /// unified log — parity debugging between surfaces (rec vs playback).
    public var debugTag: String?
    var presentCount = 0
    /// Display aids (read under renderLock; use setAssist from any thread).
    var assist = ViewAssist()

    public func setAssist(_ newValue: ViewAssist) {
        renderLock.lock()
        let changed = assist != newValue
        assist = newValue
        renderLock.unlock()
        if changed { redraw() }
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
}
