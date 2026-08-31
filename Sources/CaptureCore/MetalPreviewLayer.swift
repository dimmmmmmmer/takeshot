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
/// The draw path lives in `+Render`. The state below is internal rather than
/// private for exactly that reason — never wider than the module.
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
    /// The aids, for the GEOMETRY half only — the desqueeze and the punch-in
    /// this surface places its picture with. Everything that paints on the
    /// picture is already on the frame when it arrives (see `AssistStage`).
    /// The assist stage's geometry, under `stateLock` — NOT `renderLock`.
    ///
    /// It was under `renderLock`, which is the one lock this file says a
    /// settings change must never wait on: `render()` holds it across
    /// `nextDrawable()`, which parks for up to a second on an occluded window.
    /// So every zebra slider tick, every punch-in pinch and every false-colour
    /// toggle — all of them on the MainActor — could block the main thread on
    /// GPU work. `setLetterbox` beside it already had this right.
    ///
    /// Read with `currentAssist`; write with `setAssist`, from any thread.
    var assist = ViewAssist()
    /// The primaries the layer's colorspace is currently built for. Compared
    /// against every presented frame's own tag so a Rec.2020 source can be
    /// converted to the display profile by ColorSync instead of being shown as
    /// if it were Rec.709 (see `adoptColorSpace`). Render-queue confined.
    var installedPrimaries: CFString =
        kCVImageBufferColorPrimaries_ITU_R_709_2

    public func setAssist(_ newValue: ViewAssist) {
        stateLock.lock()
        let changed = assist != newValue
        assist = newValue
        stateLock.unlock()
        if changed { redraw() }
    }

    /// The assist as one copy, taken at the top of a pass.
    ///
    /// Copied out rather than read field by field: a gesture writing halfway
    /// through a pass would otherwise draw a frame with the old desqueeze and
    /// the new pan, which is a picture that never existed.
    var currentAssist: ViewAssist {
        stateLock.lock()
        defer { stateLock.unlock() }
        return assist
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
