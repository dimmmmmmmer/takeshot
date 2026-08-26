import Foundation

/// How the operator ENTERS and READS the pre-roll.
///
/// Frames is the default and, whichever unit is selected, the only thing that
/// is ever stored: a seconds entry is converted on the way in and thrown away.
/// The unit is a preference about the FIELD, not about the setting, which is
/// why it can be offered at all — a switch that decided how many frames the
/// ring holds would be a second answer to a question `preRollFrames` already
/// answers, and those are the ones that drift.
public enum PreRollUnit: String, Sendable, CaseIterable, Identifiable {
    /// Frames — the stored truth, and what the ring actually holds.
    case frames
    /// Seconds — converted at the signal's rate on the way in and back again
    /// for the readout. Nothing downstream of the field ever sees it.
    case seconds

    public var id: String { rawValue }
}

/// The pre-roll setting's arithmetic, in one place.
///
/// There are three ways to ask for a pre-roll — a typed frame count, a typed
/// seconds value, and a legacy `preRollSeconds` off an old settings blob — and
/// exactly one number that can come out of them, because the ring holds frames.
/// Every one of them lands on `preRollFrames(seconds:atFrameRate:)` and the
/// same range, so the two units cannot come to disagree about what "the
/// maximum" is and the memory ceiling downstream only ever sees a frame count.
extension CaptureSignalSettings {
    /// The rate a pre-roll in SECONDS is converted at when there is no signal
    /// to ask.
    ///
    /// Not a rare branch: a settings sheet is most likely to be open before
    /// anything is connected, which is exactly when nothing can be measured.
    /// 25 because that is what the retired seconds field always meant — the
    /// conversion used to be a hard-coded `* 25` — so a legacy value read with
    /// no signal up comes back as every previous build read it, and only a REAL
    /// rate moves it.
    public static let assumedPreRollFrameRate: Double = 25

    /// The pre-roll the settings pane allows, in FRAMES.
    ///
    /// Stated here rather than as a literal in the view because BOTH entry
    /// units clamp against it: a seconds entry becomes a frame count and then
    /// meets this, exactly as a typed frame count does. A second bound beside
    /// it — a "maximum seconds" — is how the two units start disagreeing, and
    /// it would also be a way around the ring's memory ceiling.
    public static let preRollFrameRange: ClosedRange<Int> = 0...100

    /// The pre-roll of an install that has never set one.
    public static let defaultPreRollFrames = 5

    /// The rate to convert seconds at: the signal's, or the assumption above
    /// when nothing is up (or the signal has not stated a rate yet).
    public static func preRollRate(of frameRate: Double?) -> Double {
        guard let frameRate, frameRate > 0, frameRate.isFinite else {
            return assumedPreRollFrameRate
        }
        return frameRate
    }

    /// Seconds → frames at a rate, clamped to what the pane allows.
    ///
    /// The one conversion in the app: the seconds field, the legacy value below
    /// and the readout all come through here. It used to be spelled `* 25` at
    /// its single call site, which is the right answer on exactly one signal —
    /// a legacy 1-second pre-roll came back as 25 frames on a 23.976 source
    /// (where it is 24) and on a 50 (where it is 50), silently, in the number of
    /// frames of head every take of the day carries.
    public static func preRollFrames(seconds: Double,
                                     atFrameRate frameRate: Double?) -> Int {
        let range = preRollFrameRange
        guard seconds.isFinite, seconds > 0 else { return range.lowerBound }
        let frames = (seconds * preRollRate(of: frameRate)).rounded()
        // clamped while it is still a Double: `Int(1e30)` traps, and the seconds
        // field is free text an operator can paste anything into
        guard frames < Double(range.upperBound) else { return range.upperBound }
        return max(range.lowerBound, Int(frames))
    }

    /// Frames → seconds at a rate — the other half of the readout, and what the
    /// seconds field shows when it is switched on.
    public static func preRollSeconds(frames: Int,
                                      atFrameRate frameRate: Double?) -> Double {
        Double(frames) / preRollRate(of: frameRate)
    }

    /// The unit the field is displayed in; frames unless the operator chose
    /// otherwise. A stored value that is not a `PreRollUnit` reads as frames
    /// rather than as nothing, like every other string-backed setting here.
    public var preRollUnitEffective: PreRollUnit {
        preRollUnit.flatMap(PreRollUnit.init(rawValue:)) ?? .frames
    }

    /// Effective pre-roll in FRAMES — the stored truth.
    ///
    /// `frameRate` is the CURRENT signal's rate (`CaptureFormat.frameRate`, i.e.
    /// `CapturePipeline.format` in the core and `CaptureController.signalFormat`
    /// in the app), nil when no signal is up. It is used for one thing only:
    /// reading a LEGACY `preRollSeconds` off a settings blob written before the
    /// setting was frames.
    ///
    /// **Once a frame count is stored, the rate cannot move it.** A signal
    /// changing from 25 to 50 between setups does not double the operator's
    /// pre-roll behind their back — the first branch below never looks at the
    /// rate. That is the whole reason frames is the stored unit: seconds is a
    /// question about a signal that may not be the one running when the take is
    /// recorded, and frames is an answer that stays true.
    ///
    /// The stored count is clamped to the same range the pane offers, so a
    /// hand-edited blob asking for 5000 frames of 12-bit UHD cannot reach the
    /// ring with a number the field would have refused.
    public func preRollFramesEffective(atFrameRate frameRate: Double?) -> Int {
        let range = Self.preRollFrameRange
        if let preRollFrames {
            return min(range.upperBound, max(range.lowerBound, preRollFrames))
        }
        if let preRollSeconds {
            return Self.preRollFrames(seconds: preRollSeconds,
                                      atFrameRate: frameRate)
        }
        return Self.defaultPreRollFrames
    }
}
