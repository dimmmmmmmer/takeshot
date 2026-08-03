@preconcurrency import CoreImage
@preconcurrency import CoreVideo
import Foundation

/// The operator aids, burned into the DISPLAY frame — one pass per frame, for
/// every surface that frame reaches.
///
/// **Why it is here and not in the preview layer.** The aids used to be applied
/// inside `MetalPreviewLayer.render`, once per mounted surface. That works for
/// windows and for nothing else: the hardware playout, the phone multiview and
/// the director's monitor are handed a pixel buffer, not a layer, so none of
/// them ever saw a false colour or a frameline (owner item 7). The chroma key
/// had already solved the same problem by living in the display stage — this
/// follows it exactly, one stage later, and inherits the rule that comes with
/// that place: **the display buffer is what MIRRORS the viewer, and the
/// deliverables are taken from the record/leveled branch before it.**
///
/// So an assist can never reach a recording, a still grab or the scopes'
/// measurement. `CapturePipeline+Frame` writes, grabs and analyzes before the
/// display hop happens at all; `PlaybackFrameTap` and `RawPlayerModel` keep
/// their own `lastBuffer` clean and hand this stage a copy on the way out.
/// `AssistIntegrityTests` pixel-proves both halves.
///
/// **What it costs when off.** One `Bool` read per frame: with no colour tool,
/// no zebra, no peaking and no guides there is nothing to draw and the original
/// buffer is passed straight through.
///
/// @unchecked Sendable: the settings the main actor hands over cross under
/// `lock` — deliberately not the render lock, because a display-only tool must
/// never make a slider tick wait on a GPU pass. The render itself takes
/// `renderLock`. Two producers own a stage each and drive it from one queue, so
/// that lock is uncontended for them; the RAW player is the exception and needs
/// it — its decode task and a `setViewAssist` on the main actor can genuinely
/// ask for a render at the same moment, and a `CIContext` and a buffer pool
/// shared across that is a crash nobody could reproduce.
public final class AssistStage: @unchecked Sendable {
    private let context: CIContext
    private let pool = PixelBufferPool()
    private let lock = NSLock()
    private let renderLock = NSLock()
    private var assist = ViewAssist()
    /// Frames shown WITHOUT the aids because they were already late.
    private var lateDropCount = 0

    public init() {
        // Its own context, like the keyer's: the pipeline's belongs to the
        // capture queue (levels, LUT, compare) and this runs on the display
        // queue. A context holds caches sized for the work it has seen.
        context = CIContext(options: [.cacheIntermediates: false])
    }

    /// The aids to draw from now on. Any thread.
    public func setAssist(_ newValue: ViewAssist) {
        lock.lock()
        assist = newValue
        lock.unlock()
    }

    /// Whether there is anything to draw at all — what a producer asks before
    /// re-delivering a paused frame.
    public var hasWork: Bool {
        lock.lock()
        defer { lock.unlock() }
        return assist.anyToolActive || !assist.guides.isEmpty
    }

    /// How many frames reached this stage past their own frame interval and
    /// were shown without the aids rather than held up. A diagnostic, not a
    /// control (see `CapturePipeline.chromaKeyLateDrops` for the same idea).
    public var lateDrops: Int {
        lock.lock()
        defer { lock.unlock() }
        return lateDropCount
    }

    /// The frame with the aids on it, or nil for "show the original" — nothing
    /// is switched on, the frame is already stale, or the render failed. A
    /// failed render must never hand uninitialized pool memory to a surface.
    ///
    /// `deadline` is in uptime nanoseconds. Past it the EFFECT is what gets
    /// dropped, never the frame: the operator would rather lose the zebra for
    /// one frame than watch the picture stutter.
    public func rendered(_ pixelBuffer: CVPixelBuffer,
                         deadline: UInt64) -> CVPixelBuffer? {
        lock.lock()
        let current = assist
        lock.unlock()
        guard current.anyToolActive || !current.guides.isEmpty else { return nil }
        guard DispatchTime.now().uptimeNanoseconds <= deadline else {
            lock.lock()
            lateDropCount += 1
            lock.unlock()
            return nil
        }
        renderLock.lock()
        defer { renderLock.unlock() }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0,
              let out = pool.buffer(width: width, height: height) else { return nil }
        // raw code values on both ends, like every other stage in the display
        // path: the palettes are defined on gamma-encoded codes, and a managed
        // render here would meter values nobody in this app ever sees
        let source = CIImage(cvPixelBuffer: pixelBuffer,
                             options: [.colorSpace: NSNull()])
        var image = source
        if current.anyToolActive {
            image = AssistFilters.applied(source, assist: current)
        }
        image = current.guides.drawn(over: image)
        // last, and over the matte: the legend is the key to the colours the
        // stage has just painted, and a frameline drawn on top of it would dim
        // the one thing on the frame that has to be read literally
        image = current.legend.drawn(over: image, tool: current.colorTool)
        let destination = CIRenderDestination(pixelBuffer: out)
        destination.colorSpace = nil
        guard let task = try? context.startTask(toRender: image, to: destination),
              (try? task.waitUntilCompleted()) != nil else { return nil }
        return out
    }

    /// No deadline: for the producers that do not carry one.
    ///
    /// The capture pipeline stamps every frame with the moment it stops being
    /// worth extra work, because its display queue is fed from a wire that will
    /// not wait. The playback tap and the RAW loop pull frames themselves, at
    /// their own pace, on their own serial queues — a slow render there simply
    /// delivers fewer frames, which is what the LUT and the compare composite
    /// ahead of it already do. And on a PAUSED clip dropping the effect would
    /// mean the operator's click did nothing at all.
    public func rendered(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        rendered(pixelBuffer, deadline: .max)
    }
}
