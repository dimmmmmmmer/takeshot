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

    public init(startDebounceFrames: Int = 4, stopDebounceFrames: Int = 12) {
        self.startDebounceFrames = max(1, startDebounceFrames)
        self.stopDebounceFrames = max(1, stopDebounceFrames)
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
        if let trigger = sample.vancTrigger {
            switch trigger {
            case .recordStart where !isRecording:
                beginRecording()
                return .started(atIndex: sample.index, timecode: sample.timecode)
            case .recordStop where isRecording:
                endRecording()
                return .stopped(atIndex: sample.index)
            default:
                break
            }
        }

        switch movement(of: sample) {
        case .advancing:
            stallRunLength = 0
            if !isRecording {
                if advanceRunLength == 0 {
                    // first frame of movement — the previous frame is already part
                    // of the take (TC "started" between the previous and current frame)
                    runStartIndex = max(0, sample.index - 1)
                    runStartTimecode = lastTimecode
                }
                advanceRunLength += 1
                if advanceRunLength >= config.startDebounceFrames {
                    beginRecording()
                    return .started(atIndex: runStartIndex, timecode: runStartTimecode)
                }
            }

        case .stalled:
            advanceRunLength = 0
            if isRecording {
                if stallRunLength == 0 { stallStartIndex = sample.index }
                stallRunLength += 1
                if stallRunLength >= config.stopDebounceFrames {
                    endRecording()
                    return .stopped(atIndex: max(0, stallStartIndex - 1))
                }
            }

        case .discontinuity:
            // TC jump: while recording it means the camera stopped (and maybe
            // immediately started a new take — the next run of advancing frames catches it)
            advanceRunLength = 0
            if isRecording {
                endRecording()
                return .stopped(atIndex: max(0, sample.index - 1))
            }

        case .noData:
            advanceRunLength = 0
            if isRecording {
                if stallRunLength == 0 { stallStartIndex = sample.index }
                stallRunLength += 1
                if stallRunLength >= config.stopDebounceFrames {
                    endRecording()
                    return .stopped(atIndex: max(0, stallStartIndex - 1))
                }
            }
        }

        return nil
    }

    // MARK: - private

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
        // stall, and a step of exactly 1 frame as movement
        let delta = tc.frameNumber - last.frameNumber
        switch delta {
        case 0: return .stalled
        case 1: return .advancing
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
