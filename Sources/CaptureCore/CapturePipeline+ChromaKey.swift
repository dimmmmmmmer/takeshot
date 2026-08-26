@preconcurrency import CoreVideo
import Foundation

/// The chroma key's half of the pipeline: where it sits in the display path,
/// what it is allowed to reach, and the pixel the eyedropper reads.
///
/// **Where it sits.** One stage after the viewing LUT, on the DISPLAY queue.
/// The LUT's rule is that the display buffer is what mirrors the viewer —
/// the preview sinks and the hardware monitor draw it — while the deliverables
/// (the writer's frame, the still grab, the scopes' measurement) are taken from
/// the record/leveled branch before it. The key follows that rule exactly: it
/// is composited into the frame the OPERATOR'S surfaces get and into nothing
/// else. `enqueuePreview` publishes the CLEAN frame for the compare provider
/// and for the phone camera grid, and hands the keyed one only to the viewer
/// and the playout; `serveFrameGrab` has already run by the time this is reached
/// (see `+Frame` for the order), on the frame the TAKE is carrying — which is the
/// untouched one unless a bake was asked for, below.
///
/// **What it costs when off.** One `Bool` read per frame.
///
/// **And when it is baked in.** `ChromaKey.record` composites the key into the
/// file as well, through the mechanism the viewing LUT's `lut_record` already
/// established: the writer is handed the DISPLAY buffer for that take, and the
/// take is tagged with what was done to it. Three consequences are stated here
/// because they are the whole of what a baked take means:
///
/// - **It runs on the CAPTURE queue, in a keyer of its own.** The display keyer
///   cannot be reused: its queue is latest-wins and drops the effect on a late
///   frame on purpose, and a file may drop neither. So a bake costs the capture
///   queue one CoreImage pass per frame while a take is rolling (measured on the
///   display queue at 1.5 ms / 1080p and 3.3 ms / UHD), and one `Bool` read per
///   frame the rest of the time — including while the switch is armed and
///   nothing is recording, which is when there is no file for the pass to be
///   for.
/// - **The take latches what it opened with**, key values included. See
///   `takeChromaKey`: the record buffer's pixel format follows the answer, and
///   an operator dragging the tolerance is not allowed to change the format
///   under an open `AVAssetWriter` — nor to make the plate jump inside one file.
/// - **The scopes do not change.** They read the wire, before this stage and
///   before the display table, so they still measure what the CAMERA sent. That
///   is the right thing to expose against and it is no longer a measurement of
///   the file: in the screen area the file holds the plate, which was never on
///   the wire and never on a scope.
extension CapturePipeline {
    /// The operator's key settings.
    ///
    /// Two confined copies out of one call, and no lock in either per-frame
    /// path: `storedChromaKey` under `chromaLock` for the display stage (called
    /// from the main actor on every slider tick, so a hop onto the capture queue
    /// is exactly what a display-only tool must not do), and `recordChromaKey`
    /// on the capture queue for the bake — the same shape `setLUT` uses, and the
    /// reason the capture queue never waits on a lock the main actor holds.
    ///
    /// **The hop is taken only when a bake is involved on one side of it or the
    /// other.** This is called from `setViewAssist`, i.e. on every tick of every
    /// assist slider in the app, and the promise this whole feature rests on is
    /// that it never touches per-frame capture work. So an operator who is not
    /// baking pays nothing on the capture queue however hard they drag — and the
    /// tick that ARMS a bake carries the whole current key across, so the value
    /// the capture side latches at take open is never a stale one.
    public func setChromaKey(_ key: ChromaKey) {
        // `let`, not a clamped `var`: the value is carried across a queue hop
        // below, and capturing a mutable local in concurrent code is a warning
        // the compiler is right about — it is the same value on both sides only
        // by accident of nobody writing to it afterwards.
        let clamped: ChromaKey = {
            var value = key
            value.clamp()
            return value
        }()
        chromaLock.lock()
        let bakedBefore = storedChromaKey.record && storedChromaKey.isOn
        storedChromaKey = clamped
        let plate = storedChromaPlate
        chromaLock.unlock()
        guard bakedBefore || (clamped.record && clamped.isOn) else { return }
        queue.async { self.adoptRecordChromaKey(clamped, plate: plate) }
    }

    /// The capture queue's copy, plus the keyer the bake needs.
    ///
    /// The keyer is built on the edge rather than lazily on the first baked
    /// frame: a `CIContext` is not free to construct, and constructing one
    /// inside a take is a spike on the queue that owns per-frame work. It is
    /// never torn down again — an operator who armed the bake once will arm it
    /// again, and a released context would have to be rebuilt on that edge.
    private func adoptRecordChromaKey(_ key: ChromaKey, plate: CVPixelBuffer?) {
        let was = recordBakesDisplayBuffer
        recordChromaKey = key
        dropPreRollOnFormatChange(was: was)
        guard key.record, key.isOn, recordChromaKeyer == nil else { return }
        let keyer = ChromaKeyer()
        keyer.setBackgroundImage(plate)
        recordChromaKeyer = keyer
    }

    /// The pre-roll ring holds what the WRITER gets, so a change to which buffer
    /// that is makes every frame already in it the wrong shape. Drop them.
    ///
    /// This is not tidiness. The ring is filled frame by frame, so flipping a
    /// bake switch while the pipeline stands by leaves a ring holding wire frames
    /// under display frames — and `drainPreRoll` would hand both to one writer,
    /// which is a pixel-format change inside an open `AVAssetWriter` session. It
    /// costs the lead of the NEXT take only, and only on the frame the operator
    /// clicked; a mixed take costs the take. The frames it drops are the same
    /// ones a short ring drops, and they are reported the same way.
    ///
    /// Called on both bake edges (here and in `setLUT`) rather than tested per
    /// frame, because the answer only changes when a switch moves. Queue-confined.
    func dropPreRollOnFormatChange(was: Bool) {
        guard was != recordBakesDisplayBuffer else { return }
        preRollBuffer.removeAll()
    }

    /// The plate that shows through the key. Handed to each keyer on the queue
    /// that owns it — the display one belongs to the display stage, the record
    /// one to the capture queue, and nothing else may touch either.
    public func setChromaBackgroundImage(_ buffer: CVPixelBuffer?) {
        chromaLock.lock()
        storedChromaPlate = buffer
        chromaLock.unlock()
        displayQueue.async { self.chromaKeyer.setBackgroundImage(buffer) }
        queue.async { self.recordChromaKeyer?.setBackgroundImage(buffer) }
    }

    /// Whether the frames going to the WRITER are display buffers rather than
    /// the camera's wire codes, because a display decision is being baked in.
    ///
    /// One predicate for the two answers that have to agree — the pre-roll ring
    /// holds what the writer gets, and the file's `levelsKey` states what the
    /// writer got — so a third bake added later cannot be wired into one of them
    /// and not the other. Queue-confined.
    var recordBakesDisplayBuffer: Bool { bakesLUT || bakesChromaKey }

    /// Whether the key is being composited into the file right now.
    ///
    /// The LATCHED answer while a take is open and the armed one otherwise: what
    /// a rolling take does is settled at `beginTake` and cannot be changed under
    /// it, and what an idle pipeline reports is what the NEXT take will do —
    /// which is what the pre-roll ring has to be holding by then.
    var bakesChromaKey: Bool {
        guard writer == nil else { return takeChromaRecord }
        return recordChromaKey.record && recordChromaKey.isOn
    }

    /// The frame the writer gets when the key is baked in: the display buffer
    /// with the LATCHED key composited into it.
    ///
    /// A failed render falls back to the uncomposited frame rather than dropping
    /// it, which is the answer `applyLUT` already gives — a hole in the picture
    /// is worse than a frame of green in it, and the take stays continuous. It
    /// is counted, because unlike a look this is content the file was supposed
    /// to carry and does not. Capture-queue only.
    func chromaBaked(_ buffer: CVPixelBuffer) -> CVPixelBuffer {
        guard let keyer = recordChromaKeyer,
              let keyed = keyer.keyed(buffer, key: takeChromaKey) else {
            // The lock is taken on the failure path only, so a working bake pays
            // nothing for the counter — and it is a lock rather than a queue hop
            // for the reason `chromaLateDropCount` is one: the reader is the main
            // actor, and the capture queue can be inside a pre-roll drain's
            // second-and-a-half of encoder waiting.
            chromaLock.lock()
            chromaBakeFallbackCount += 1
            chromaLock.unlock()
            return buffer
        }
        return keyed
    }

    /// Frames a baking take wrote without the key because the render failed.
    /// Read from the main actor for the diagnostics bundle; see the stored
    /// property for what the number means.
    public var chromaBakeFallbacks: Int {
        chromaLock.lock()
        defer { chromaLock.unlock() }
        return chromaBakeFallbackCount
    }

    /// How many frames have been shown without the key because they were
    /// already late. A diagnostic, not a control: if this climbs, the machine
    /// cannot afford the effect at this resolution and the operator is seeing
    /// it flicker.
    public var chromaKeyLateDrops: Int {
        chromaLock.lock()
        defer { chromaLock.unlock() }
        return chromaLateDropCount
    }

    /// Key a frame on its way to the surfaces. nil means "show the original":
    /// the key is off, the frame is already late, or the render failed.
    ///
    /// The lateness gate is the graceful degradation this feature promised. The
    /// display queue is latest-wins, so a slow machine cannot back frames up —
    /// but it CAN spend its whole frame interval inside the keyer and hand the
    /// surface a picture that is already a frame old. Past the deadline the
    /// effect is what gets dropped, never the frame: the operator would rather
    /// see the green screen for one frame than see the picture stutter.
    ///
    /// Display-queue only (the keyer is confined to it).
    func chromaKeyed(_ buffer: CVPixelBuffer, deadline: UInt64) -> CVPixelBuffer? {
        chromaLock.lock()
        let key = storedChromaKey
        chromaLock.unlock()
        guard key.isOn else { return nil } // off costs one Bool read
        guard DispatchTime.now().uptimeNanoseconds <= deadline else {
            chromaLock.lock()
            chromaLateDropCount += 1
            chromaLock.unlock()
            return nil
        }
        return chromaKeyer.keyed(buffer, key: key)
    }

    /// How long the display stage has to work on a frame before the frame stops
    /// being worth the work: one frame interval.
    ///
    /// One and not two: a stage that is a whole frame behind is already showing
    /// the operator a picture that has been superseded, and the cure for that
    /// is to get the newest frame on the glass, not to spend another ten
    /// milliseconds decorating a stale one. An unknown rate is treated as 25 —
    /// the slowest signal this app sees, so the guess is the generous one.
    public static func displayBudgetNanos(atFrameRate rate: Double) -> UInt64 {
        guard rate > 0, rate.isFinite else { return 40_000_000 }
        return UInt64(1_000_000_000 / rate)
    }

    /// The budget from now, in uptime nanoseconds. Capture queue (reads
    /// `format`).
    func displayDeadline() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
            + Self.displayBudgetNanos(atFrameRate: format?.frameRate ?? 0)
    }

    // MARK: - the eyedropper

    /// The color at a point on the DISPLAYED picture, given as fractions of the
    /// frame (0,0 top-left). nil when there is no frame, or it is not the 8-bit
    /// BGRA the display path produces.
    ///
    /// This reads the clean display frame — what the operator is looking at
    /// before the key is applied — because that is the pixel they are pointing
    /// at. Reading the keyed frame would sample the background the previous
    /// guess had already put there.
    ///
    /// A small neighborhood is averaged rather than one pixel: a cyc is noisy,
    /// and a single sample off a compressed HDMI feed can be several code
    /// values away from the green the operator means to pick.
    public func sampleDisplayColor(atFractionX u: Double, y v: Double,
                                   radius: Int = 2) -> ChromaKey.RGB? {
        latestPreviewLock.lock()
        let buffer = latestPreview
        latestPreviewLock.unlock()
        guard let buffer,
              CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA
        else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0 else { return nil }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let cx = min(width - 1, max(0, Int(u * Double(width))))
        let cy = min(height - 1, max(0, Int(v * Double(height))))
        var sum = (b: 0, g: 0, r: 0)
        var counted = 0
        for y in (cy - radius)...(cy + radius) where y >= 0 && y < height {
            let row = bytes + y * rowBytes
            for x in (cx - radius)...(cx + radius) where x >= 0 && x < width {
                sum.b += Int(row[x * 4])
                sum.g += Int(row[x * 4 + 1])
                sum.r += Int(row[x * 4 + 2])
                counted += 1
            }
        }
        guard counted > 0 else { return nil }
        let scale = 255.0 * Double(counted)
        return ChromaKey.RGB(Double(sum.r) / scale, Double(sum.g) / scale,
                             Double(sum.b) / scale)
    }
}
