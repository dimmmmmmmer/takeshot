import Foundation

/// An explicit REC trigger recognized in VANC packets (vendor-specific).
public enum VancTrigger: Equatable, Sendable {
    case recordStart
    case recordStop
}

/// One input frame as seen by the detector.
public struct FrameSample: Sendable {
    public var index: Int               // running capture frame counter
    public var timecode: Timecode?
    public var vancTrigger: VancTrigger?

    public init(index: Int, timecode: Timecode?, vancTrigger: VancTrigger? = nil) {
        self.index = index
        self.timecode = timecode
        self.vancTrigger = vancTrigger
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
/// Rec Run) and from VANC triggers (take priority when recognized).
///
/// A pure state machine with no hardware dependencies — all logic is tested on synthetic data.
public final class RecDetector {
    public private(set) var isRecording = false

    private let config: RecDetectorConfig
    private var lastTimecode: Timecode?
    private var lastIndex: Int = -1

    // start accumulation
    private var advanceRunLength = 0
    private var runStartIndex = 0
    private var runStartTimecode: Timecode?

    // stop accumulation
    private var stallRunLength = 0
    private var stallStartIndex = 0

    public init(config: RecDetectorConfig = RecDetectorConfig()) {
        self.config = config
    }

    public func reset() {
        isRecording = false
        lastTimecode = nil
        lastIndex = -1
        advanceRunLength = 0
        stallRunLength = 0
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

        // VANC-only: no timecode-movement starts or stalls-based stops
        if config.vancOnly {
            return nil
        }

        // One row of the state table per case: what the timecode did on this
        // frame decides which accumulator moves.
        switch movement(of: sample) {
        case .advancing:
            return accumulateAdvance(at: sample.index)

        case .stalled:
            return accumulateStall(at: sample.index)

        case .discontinuity:
            return handleDiscontinuity(at: sample.index)

        case .noData:
            // no timecode on the wire at all — same stop accumulation as a
            // stalled one: both mean "the camera is not laying down frames"
            return accumulateStall(at: sample.index)
        }
    }

    // MARK: - private

    /// The explicit-trigger row of the table: a recognized VANC start/stop
    /// takes effect on the spot, no debounce. A trigger that repeats the state
    /// we are already in (start while recording, stop while idle) is ignored,
    /// and the timecode machine below still gets the frame.
    private func vancEvent(for sample: FrameSample) -> RecEvent? {
        guard let trigger = sample.vancTrigger else { return nil }
        switch trigger {
        case .recordStart where !isRecording:
            beginRecording()
            return .started(atIndex: sample.index, timecode: sample.timecode)
        case .recordStop where isRecording:
            endRecording()
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
        beginRecording()
        return .started(atIndex: runStartIndex, timecode: runStartTimecode)
    }

    /// TC stood still (or was absent): run up the stop debounce while
    /// recording. The take's last frame is the one before the stall began.
    private func accumulateStall(at index: Int) -> RecEvent? {
        advanceRunLength = 0
        guard isRecording else { return nil }
        if stallRunLength == 0 { stallStartIndex = index }
        stallRunLength += 1
        guard stallRunLength >= config.stopDebounceFrames else { return nil }
        endRecording()
        return .stopped(atIndex: max(0, stallStartIndex - 1))
    }

    /// TC jump: while recording it means the camera stopped (and maybe
    /// immediately started a new take — the next run of advancing frames catches it)
    private func handleDiscontinuity(at index: Int) -> RecEvent? {
        advanceRunLength = 0
        guard isRecording else { return nil }
        endRecording()
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
        guard let last = lastTimecode else {
            // first TC — the reference point, no movement yet
            return .stalled
        }
        // capture may report one TC per pair of frames (PsF) — treat a repeat as
        // stall, and a step of exactly 1 frame as movement. A 24h wrap
        // (23:59:59:MM → 00:00:00:00) is one frame too, not a discontinuity.
        let dayFrames = Timecode.dayFrames(fps: tc.fps,
                                           isDropFrame: tc.isDropFrame)
        let delta = tc.frameNumber - last.frameNumber
        switch delta {
        case 0: return .stalled
        case 1, 1 - dayFrames: return .advancing
        default: return .discontinuity
        }
    }

    private func beginRecording() {
        isRecording = true
        advanceRunLength = 0
        stallRunLength = 0
    }

    private func endRecording() {
        isRecording = false
        advanceRunLength = 0
        stallRunLength = 0
    }
}
