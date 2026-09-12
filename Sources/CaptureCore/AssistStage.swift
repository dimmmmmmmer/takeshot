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
    /// What the bars around a reframed picture are painted in — the operator's
    /// own player background, the same colour the preview layer uses for the
    /// bars it paints around a fitted frame.
    private var letterbox = CIColor(red: 0, green: 0, blue: 0)
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

    /// The colour the bars around a reframed picture take. Any thread.
    ///
    /// Here as well as on the surfaces because the geometry is here now: a
    /// rotated or shrunk picture has black around it INSIDE the signal's
    /// raster, and those bars are in the delivered frame — they reach the
    /// hardware playout and the multiview, which have no layer to paint them.
    public func setLetterbox(_ color: CIColor) {
        lock.lock()
        letterbox = color
        lock.unlock()
    }

    /// **What this stage was last told to draw.** A diagnostic accessor like
    /// `lateDrops` beside it, and the only way to ask a SURFACE what it
    /// actually received rather than asking the controller what it meant to
    /// send: with a geometry per surface, those are two different questions
    /// and the suite has to be able to tell them apart.
    public var currentAssist: ViewAssist {
        lock.lock()
        defer { lock.unlock() }
        return assist
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
        let bars = letterbox
        lock.unlock()
        guard current.anyToolActive || !current.guides.isEmpty
            || !current.sizing.isIdentity else { return nil }
        // **Past the deadline the AIDS go and the framing stays.**
        //
        // The rule was "drop the effect, never the frame", and it is still
        // that — but a reframe is not an effect. An aid missing for one frame
        // costs the operator a zebra; a framing missing for one frame is the
        // whole picture jumping to another position and back, on the
        // director's monitor as well as here, which is far worse than the
        // stutter the deadline exists to prevent. So a late frame loses the
        // tools, the guides and the legend and keeps its geometry — and with
        // no geometry to keep, it is passed through exactly as before.
        let late = DispatchTime.now().uptimeNanoseconds > deadline
        if late {
            lock.lock()
            lateDropCount += 1
            lock.unlock()
            guard !current.sizing.isIdentity else { return nil }
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
        if !late {
            if current.anyToolActive {
                image = AssistFilters.applied(source, assist: current)
            }
            image = current.guides.drawn(over: image)
            // last, and over the matte: the legend is the key to the colours
            // the stage has just painted, and a frameline drawn on top of it
            // would dim the one thing on the frame that has to be read
            // literally
            image = current.legend.drawn(over: image, tool: current.colorTool)
        }
        // **The geometry, LAST** — after everything that measures.
        //
        // It used to be applied per surface, in `MetalPreviewLayer`, which
        // meant the operator's reframe existed in the operator's own window
        // and nowhere else: the hardware playout, the multiview, the phone
        // grid and every browser stream are handed a pixel buffer rather than
        // a layer, so the director's monitor showed a picture nobody had
        // framed. That is the same gap the aids above were moved here to
        // close, one stage further on.
        //
        // Last and not first, and that is the contract rather than an order of
        // convenience: false colour, zebra and peaking read CODE VALUES, and a
        // reframe RESAMPLES — measuring interpolated pixels would make the
        // exposure tools answer for a picture the camera never sent. The
        // guides and the legend ride it deliberately (a frameline marks the
        // framing, so it moves with the frame), which is the order the preview
        // layer applied for as long as it owned this.
        //
        // Into the SIGNAL's own raster, which is what makes the answer one
        // answer: a viewport is a property of a window, and every surface has
        // a different one.
        image = current.sizing.applied(
            to: image, in: CGRect(x: 0, y: 0, width: width, height: height),
            letterbox: bars)
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
