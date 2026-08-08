@preconcurrency import CoreVideo
import Foundation

/// The taught-indicator watcher's half of the pipeline: which queue it runs on,
/// how often, what it is allowed to read, and the latch the detector reads back.
///
/// **Never on the capture queue.** The pass is offered exactly the way the scope
/// analyzer's is — own queue at utility QoS, a busy gate for latest-wins
/// coalescing, and a stride computed from a target RATE rather than a frame
/// count so the delivered rate is the same at 25 and at 60 fps. A record
/// indicator does not need 25 Hz: `visualRecUpdatesPerSecond` is 5, which is
/// five times faster than a camera can flash a dot. What the frame path spends
/// is one integer comparison per frame, and one uncontended lock every fifth
/// frame.
///
/// The pass itself is 0.004 ms in release at 1080p and the same at UHD — the tap
/// count is fixed, so the cost does not move with the raster (measured; see
/// `VisualRecSampler`). Five of those a second is 0.002 % of a core, which is
/// why the rate is set by what a blinking dot needs rather than by what the
/// analysis costs.
///
/// **Analysis only.** Everything here READS. The frame it reads is the leveled
/// display buffer — before the viewing LUT, which is the stage the operator's
/// references were captured from, so a look switched on afterwards cannot move a
/// take — and nothing it computes is written to a pixel anywhere. It reaches the
/// recorded file, the still grab, the scopes and the mirrors nowhere at all;
/// `VisualRecIntegrityTests` records real ProRes and reads the pixels back to
/// keep that true.
extension CapturePipeline {
    /// Passes per second the frame path aims for while the trigger is armed.
    ///
    /// Five. A camera that flashes its indicator does so around 1 Hz, so five
    /// readings a second sees both halves of every blink with room to spare, and
    /// the confirm-frame hysteresis is counted in these readings (see
    /// `RecDetector+Visual`) — a rate an operator's stop confirm of 12 turns into
    /// 2.4 s of tolerance.
    public static let visualRecUpdatesPerSecond = 5.0

    /// Frames between the passes the frame path offers the watcher, at a given
    /// signal rate. Extracted for the same reason `scopeStride` is: the
    /// arithmetic can then be asserted without a stopwatch.
    public static func visualRecStride(atFrameRate frameRate: Double) -> Int {
        max(1, Int((frameRate / visualRecUpdatesPerSecond).rounded()))
    }

    // MARK: - what the operator taught

    /// Hand over the teaching. Takes a lock rather than a queue hop, for the
    /// reason `setChromaKey` does: this is called from the main actor while the
    /// operator drags a slider, and hopping onto the capture queue is exactly
    /// what a feature that must not touch per-frame work may not do.
    ///
    /// Disarming CLEARS the latch, so a reading taken while the trigger was on
    /// cannot be acted on after it was switched off.
    public func setVisualRec(_ teaching: VisualRecTeaching) {
        var clamped = teaching
        clamped.clamp()
        visualRecLock.lock()
        storedVisualRec = clamped
        if !clamped.isArmed {
            storedVisualRecReading = nil
            storedVisualRecPosition = nil
        }
        visualRecLock.unlock()
    }

    /// The teaching as the watcher is using it. Safe from any thread.
    public var visualRec: VisualRecTeaching {
        visualRecLock.lock()
        defer { visualRecLock.unlock() }
        return storedVisualRec
    }

    /// The latest reading, or nil for "no evidence". Safe from any thread — the
    /// panel's live readout and the diagnostics bundle both ask for it.
    public var visualRecReading: VisualRecReading? {
        visualRecLock.lock()
        defer { visualRecLock.unlock() }
        return storedVisualRecReading
    }

    /// Where the latest measured frame sat on the taught axis, and how far off
    /// it — the honest readout while the operator is teaching (see
    /// `VisualRecTeaching.position`). nil before the first pass.
    public var visualRecPosition: (along: Double, residual: Double)? {
        visualRecLock.lock()
        defer { visualRecLock.unlock() }
        return storedVisualRecPosition
    }

    /// Sample the box on the frame that is on screen right now — the teach
    /// capture, one reference per press.
    ///
    /// The PRE-LUT display buffer, which is what the watcher reads too: the
    /// reference and every later reading are then in one domain by construction.
    /// nil when no frame has arrived, or when the current one is not the 8-bit
    /// BGRA the display path produces.
    public func captureVisualRecSignature() -> VisualRecSignature? {
        latestPreviewLock.lock()
        let buffer = latestPreLUT
        latestPreviewLock.unlock()
        guard let buffer else { return nil }
        return VisualRecSampler.signature(of: buffer, region: visualRec.region)
    }

    // MARK: - the per-frame path

    /// The latched reading, read on the capture queue by `runDetector`.
    ///
    /// A latch and not a per-frame measurement: the watcher answers a few times
    /// a second, so most frames carry the answer an earlier one produced. That is
    /// the whole reason the confirm runs count MEASURED frames rather than every
    /// frame — see `RecDetector+Visual`.
    func latchedVisualRecReading() -> VisualRecReading? {
        visualRecLock.lock()
        defer { visualRecLock.unlock() }
        // A latch that is only ever written by the watcher would keep answering
        // after the trigger was switched off; `setVisualRec` clears it, and this
        // re-checks the arming so a stale reading cannot outlive a disarm that
        // raced it.
        guard storedVisualRec.isArmed else { return nil }
        return storedVisualRecReading
    }

    /// Offer this frame to the watcher, unless one pass is already in flight or
    /// the stride has not come round.
    ///
    /// Capture queue. Chosen inside the guards on purpose, exactly like
    /// `analyzeScopes`: with the trigger disarmed the only cost is the stride
    /// comparison and one lock acquisition every fifth frame, and the frame
    /// buffer is not even retained.
    func watchVisualRec(_ display: CVPixelBuffer) {
        guard !visualRecBusy else { return }
        let stride = Self.visualRecStride(atFrameRate: format?.frameRate ?? 25)
        guard frameIndex - lastVisualRecFrame >= stride else { return }
        // Advanced before the arming check so a disarmed trigger takes the lock
        // once per stride rather than once per frame.
        lastVisualRecFrame = frameIndex
        visualRecLock.lock()
        let teaching = storedVisualRec
        visualRecLock.unlock()
        // Mirrored for the pre-roll ring, which is sized on the capture queue and
        // must not take this lock per frame (see `preRollCapacity`).
        visualRecArmed = teaching.isArmed
        guard teaching.isArmed else { return }
        visualRecBusy = true
        let frame = display // retained: the pool must not recycle it under us
        visualRecQueue.async { [weak self] in
            let signature = VisualRecSampler.signature(of: frame,
                                                       region: teaching.region)
            let position = signature.flatMap { teaching.position(of: $0) }
            let reading = signature.flatMap { teaching.reading(of: $0) }
            guard let pipeline = self else { return }
            pipeline.queue.async { pipeline.visualRecBusy = false }
            pipeline.publishVisualRec(reading: reading, position: position)
        }
    }

    /// Latch a pass's result and, when it CHANGED, tell the main actor.
    ///
    /// On change only: the readout exists so the operator can see the box
    /// working, and republishing "still rolling" five times a second would put a
    /// main-queue hop on every pass for no new information.
    private func publishVisualRec(reading: VisualRecReading?,
                                  position: (along: Double, residual: Double)?) {
        visualRecLock.lock()
        let changed = storedVisualRecReading != reading
        storedVisualRecReading = reading
        storedVisualRecPosition = position
        visualRecLock.unlock()
        guard changed else { return }
        let report = onVisualRecReading
        DispatchQueue.main.async { report?(reading) }
    }
}
