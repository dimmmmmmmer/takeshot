import Foundation

/// An explicit REC trigger recognized in VANC packets (vendor-specific).
public enum VancTrigger: Equatable, Sendable {
    case recordStart
    case recordStop
}

/// What opened the take that is rolling.
///
/// A value rather than a comment because a spurious roll has to be diagnosable
/// on set: it rides `PipelineHealth.startTrigger` into the diagnostics bundle and
/// on to the REC indicator over the player, so "why is it recording" has an
/// answer that does not require a reconstruction after the fact.
public enum RecTrigger: String, Equatable, Sendable, Codable, CaseIterable {
    /// An explicit record trigger in the VANC data.
    case vanc
    /// Timecode that started advancing (camera in Rec Run).
    case timecode
    /// The record indicator the operator taught on the picture.
    case visual
    /// The REC button, a hotkey, or the remote.
    case manual
}

/// One input frame as seen by the detector.
public struct FrameSample: Sendable {
    public var index: Int               // running capture frame counter
    public var timecode: Timecode?
    public var vancTrigger: VancTrigger?
    /// What the taught-indicator watcher made of this frame, or nil for "no
    /// evidence" — which covers the watcher being off, the region being
    /// disturbed and the frame falling inside the margin alike, because all
    /// three must leave the confirm runs exactly where they were.
    ///
    /// The watcher runs at a few hertz on its own queue and its answer is
    /// LATCHED, so most frames carry the reading a previous frame produced (see
    /// `CapturePipeline+VisualRec`).
    public var visualRec: VisualRecReading?

    public init(index: Int, timecode: Timecode?, vancTrigger: VancTrigger? = nil,
                visualRec: VisualRecReading? = nil) {
        self.index = index
        self.timecode = timecode
        self.vancTrigger = vancTrigger
        self.visualRec = visualRec
    }
}

public enum RecEvent: Equatable, Sendable {
    /// The camera started recording. `atIndex` is the actual start frame (the
    /// first frame where TC began advancing), usually earlier than the frame the
    /// debounce fired on — the controller backfills these from the pre-roll buffer.
    case started(atIndex: Int, timecode: Timecode?)
    /// The camera stopped recording. `atIndex` is the take's last frame.
    case stopped(atIndex: Int)
}

public struct RecDetectorConfig: Equatable, Sendable {
    /// How many consecutive frames TC must advance to declare REC (glitch filter).
    public var startDebounceFrames: Int
    /// How many consecutive frames TC must stall/be absent to declare stop.
    public var stopDebounceFrames: Int
    /// VANC-only: takes start/stop exclusively on explicit VANC triggers; the
    /// timecode movement machine is disabled (otherwise every frame after a
    /// VANC start reads as a stall and the take self-terminates).
    public var vancOnly: Bool

    public init(startDebounceFrames: Int = 4, stopDebounceFrames: Int = 12,
                vancOnly: Bool = false) {
        self.startDebounceFrames = max(1, startDebounceFrames)
        self.stopDebounceFrames = max(1, stopDebounceFrames)
        self.vancOnly = vancOnly
    }
}

/// Detects the camera's REC state from running timecode (universal, camera in
/// Rec Run), from VANC triggers (take priority when recognized), and from a
/// record indicator the operator taught on the picture (`+Visual`).
///
/// A pure state machine with no hardware dependencies — all logic is tested on synthetic data.
public final class RecDetector {
    public private(set) var isRecording = false

    /// What opened the take that is rolling; nil while idle.
    ///
    /// Read by the pipeline the moment a `.started` comes back, so the take can
    /// record which trigger made it — and read inside this file, because a take
    /// the taught indicator opened is not one that timecode inference may close
    /// (see `accumulateStall`).
    public private(set) var activeTrigger: RecTrigger?

    let config: RecDetectorConfig
    private var lastTimecode: Timecode?
    private var lastIndex: Int = -1

    // start accumulation
    private var advanceRunLength = 0
    private var runStartIndex = 0
    private var runStartTimecode: Timecode?

    // stop accumulation
    private var stallRunLength = 0
    private var stallStartIndex = 0

    // The taught indicator's own confirm runs (see `+Visual`). Its own pair
    // rather than the two above, because both machines can be live at once —
    // Auto mode with the indicator armed runs the timecode rows AND these — and
    // one shared counter would let each source clear the other's evidence.
    var visualStartRun = 0
    var visualStopRun = 0
    var visualStartIndex = 0
    var visualStartTimecode: Timecode?
    var visualStopIndex = 0

    public init(config: RecDetectorConfig = RecDetectorConfig()) {
        self.config = config
    }

    public func reset() {
        isRecording = false
        activeTrigger = nil
        lastTimecode = nil
        lastIndex = -1
        advanceRunLength = 0
        stallRunLength = 0
        visualStartRun = 0
        visualStopRun = 0
    }

    public func process(_ sample: FrameSample) -> RecEvent? {
        defer {
            lastTimecode = sample.timecode ?? lastTimecode
            lastIndex = sample.index
        }

        // A VANC trigger is explicit knowledge — fires without debounce.
        if let event = vancEvent(for: sample) {
            return event
        }

        // The taught indicator, before the timecode machine and after the
        // explicit trigger — it is inference, like timecode, but it is inference
        // about the thing the operator pointed at. A row that produces nothing
        // falls through, which is what makes it COMPOSE with the modes rather
        // than replace them.
        if let reading = sample.visualRec,
           let event = visualEvent(for: reading, sample: sample) {
            return event
        }

        // VANC-only: no timecode-movement starts or stalls-based stops
        if config.vancOnly {
            return nil
        }

        // One row of the state table per case: what the timecode did on this
        // frame decides which accumulator moves.
        switch movement(of: sample) {
        case .advancing:
            return accumulateAdvance(at: sample.index)

        // no timecode on the wire at all shares the stalled row: both mean
        // "the camera is not laying down frames"
        case .stalled, .noData:
            return accumulateStall(at: sample.index)

        case .discontinuity:
            return handleDiscontinuity(at: sample.index)
        }
    }

    // MARK: - private

    /// The explicit-trigger row of the table: a recognized VANC start/stop
    /// takes effect on the spot, no debounce. A trigger that repeats the state
    /// we are already in (start while recording, stop while idle) is ignored,
    /// and the timecode machine below still gets the frame.
    private func vancEvent(for sample: FrameSample) -> RecEvent? {
        // no trigger, or a repeat of the current state, falls to the default row
        switch (sample.vancTrigger, isRecording) {
        case (.recordStart, false):
            setRecording(true, trigger: .vanc)
            return .started(atIndex: sample.index, timecode: sample.timecode)
        case (.recordStop, true):
            // Explicit knowledge closes ANY take, the taught indicator's
            // included: a camera that says it stopped has settled the question.
            setRecording(false)
            return .stopped(atIndex: sample.index)
        default:
            return nil
        }
    }

    /// TC advanced by a frame: run up the start debounce while idle. Any
    /// movement also breaks a stop run in progress.
    private func accumulateAdvance(at index: Int) -> RecEvent? {
        stallRunLength = 0
        guard !isRecording else { return nil }
        if advanceRunLength == 0 {
            // first frame of movement — the previous frame is already part
            // of the take (TC "started" between the previous and current frame)
            runStartIndex = max(0, index - 1)
            runStartTimecode = lastTimecode
        }
        advanceRunLength += 1
        guard advanceRunLength >= config.startDebounceFrames else { return nil }
        setRecording(true, trigger: .timecode)
        return .started(atIndex: runStartIndex, timecode: runStartTimecode)
    }

    /// TC stood still (or was absent): run up the stop debounce while
    /// recording. The take's last frame is the one before the stall began.
    private func accumulateStall(at index: Int) -> RecEvent? {
        advanceRunLength = 0
        guard isRecording else { return nil }
        // A take the taught indicator opened is never closed by timecode
        // inference. The visual trigger exists for cameras whose timecode does
        // not run at all, so "the timecode is not moving" is not evidence about
        // such a take — it is the normal state of one. Only the indicator going
        // away, an explicit VANC stop, or the operator ends it.
        guard activeTrigger != .visual else { return nil }
        if stallRunLength == 0 { stallStartIndex = index }
        stallRunLength += 1
        guard stallRunLength >= config.stopDebounceFrames else { return nil }
        setRecording(false)
        return .stopped(atIndex: max(0, stallStartIndex - 1))
    }

    /// TC jump: while recording it means the camera stopped (and maybe
    /// immediately started a new take — the next run of advancing frames catches it)
    private func handleDiscontinuity(at index: Int) -> RecEvent? {
        advanceRunLength = 0
        guard isRecording else { return nil }
        // Timecode inference again, and the same rule as the stall row: a jump
        // on a wire whose timecode has nothing to do with this take says
        // nothing about it.
        guard activeTrigger != .visual else { return nil }
        setRecording(false)
        return .stopped(atIndex: max(0, index - 1))
    }

    private enum Movement {
        case advancing      // TC grew by exactly 1 frame
        case stalled        // TC did not change
        case discontinuity  // TC jumped (forward/back by more than 1)
        case noData         // TC absent
    }

    private func movement(of sample: FrameSample) -> Movement {
        guard let tc = sample.timecode else { return .noData }
        // capture may report one TC per pair of frames (PsF) — treat a repeat as
        // stall, and a step of exactly 1 frame as movement. A 24h wrap
        // (23:59:59:MM → 00:00:00:00) is one frame too, not a discontinuity.
        let dayFrames = Timecode.dayFrames(fps: tc.fps,
                                           isDropFrame: tc.isDropFrame)
        // the first TC is the reference point and nothing more: measured
        // against itself it reads as the stall it is
        let delta = tc.frameNumber - (lastTimecode?.frameNumber ?? tc.frameNumber)
        switch delta {
        case 0: return .stalled
        case 1, 1 - dayFrames: return .advancing
        default: return .discontinuity
        }
    }

    /// Latch the state and clear every debounce run: the one that just fired is
    /// spent, and the others must not carry into the new state.
    ///
    /// `trigger` is what opened the take; a stop always clears it, so
    /// `activeTrigger` is non-nil exactly while `isRecording` is true.
    func setRecording(_ recording: Bool, trigger: RecTrigger? = nil) {
        isRecording = recording
        activeTrigger = recording ? trigger : nil
        advanceRunLength = 0
        stallRunLength = 0
        visualStartRun = 0
        visualStopRun = 0
    }
}
