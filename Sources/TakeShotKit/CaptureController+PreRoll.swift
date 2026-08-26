import CaptureCore
import Foundation

/// The pre-roll setting as the operator meets it: which unit the field is in,
/// what a typed value becomes, and the line that shows both readings at once.
///
/// The rules live here rather than in the view for the reason every enabling
/// condition does — a view that spells its own arithmetic is a second answer to
/// a question the controller already answers, and the two units are exactly the
/// place two answers would drift apart.
extension CaptureController {
    /// The rate the pre-roll's seconds↔frames conversion keys off.
    ///
    /// The current signal's, which is the only rate the app can measure;
    /// `signalFormat` is nil when nothing is up, and the conversion falls back
    /// to `CaptureSignalSettings.assumedPreRollFrameRate` — not a rare branch,
    /// because a settings sheet is most likely to be open before the camera is
    /// on. `preRollReading` says which of the two it used.
    var preRollFrameRate: Double? { signalFormat?.frameRate }

    /// Which unit the field is in. Display only: the value stored is a frame
    /// count whichever way this is set, so flipping it never changes the
    /// pre-roll — it changes how the same number is typed and read.
    var preRollUnit: PreRollUnit {
        get { settings.capture.preRollUnitEffective }
        set { settings.capture.preRollUnit = newValue.rawValue }
    }

    /// The pre-roll in frames — the stored truth, whatever the field shows.
    ///
    /// The setter reads the value straight back through the model's own clamp
    /// so what is stored is what every reader will see, and so that there is
    /// ONE clamp: a seconds entry arrives here having been converted, and meets
    /// the same `preRollFrameRange` a typed frame count does. The ring's memory
    /// ceiling then applies to that frame count downstream
    /// (`CapturePipeline.preRollCapacity`) and cannot be reached around by
    /// choosing the other unit.
    ///
    /// Writing also clears the legacy `preRollSeconds`: once the operator has
    /// stated a frame count, nothing may go on re-deriving one.
    var preRollFrames: Int {
        get {
            settings.capture.preRollFramesEffective(atFrameRate: preRollFrameRate)
        }
        set {
            var capture = settings.capture
            capture.preRollFrames = newValue
            capture.preRollSeconds = nil
            capture.preRollFrames = capture.preRollFramesEffective(
                atFrameRate: preRollFrameRate)
            settings.capture = capture
        }
    }

    /// The same pre-roll in seconds, for the field when the unit is seconds.
    ///
    /// Not stored and deliberately not storable: it is `preRollFrames` divided
    /// by the rate on the way out and multiplied by it on the way back in, so
    /// there is nothing here that can disagree with the frame count. A value
    /// the range refuses comes back as the clamped one on the next read, which
    /// is what makes the ceiling visible instead of silent.
    var preRollSecondsEntry: Double {
        get {
            CaptureSignalSettings.preRollSeconds(frames: preRollFrames,
                                                 atFrameRate: preRollFrameRate)
        }
        set {
            preRollFrames = CaptureSignalSettings.preRollFrames(
                seconds: newValue, atFrameRate: preRollFrameRate)
        }
    }

    /// Both readings of the pre-roll on one line — "12 frames · 0.5 s at 23.98".
    ///
    /// Shown under the field in BOTH units on purpose. A unit switch that only
    /// ever showed one of them would let an operator set 2 s on a bench with no
    /// signal and shoot it at 50, having been told nothing about the 100 frames
    /// that actually became; and the seconds reading is the one that moves when
    /// the signal changes, because the frame count does not.
    ///
    /// The rate is spelled the way the badge over the player spells it
    /// (`playerFPSText`) — one spelling of a frame rate in the app — and says
    /// so when there is no signal and the conversion is running on an
    /// assumption rather than a measurement.
    var preRollReading: String {
        let frames = preRollFrames
        let rate = CaptureSignalSettings.preRollRate(of: preRollFrameRate)
        let seconds = CaptureSignalSettings.preRollSeconds(
            frames: frames, atFrameRate: preRollFrameRate)
        let key = preRollFrameRate == nil
            ? "pre_roll_reading_assumed" : "pre_roll_reading_value"
        return L(key, String(frames), String(format: "%.2f", seconds),
                 playerFPSText(rate))
    }

    /// Settle a LEGACY seconds pre-roll into a frame count, once, the first
    /// time a real rate is known.
    ///
    /// Without this the legacy value is re-derived on every read, so an old
    /// blob's pre-roll would MOVE when the camera changed from 25 to 50 — the
    /// one thing a stored frame count exists to prevent. Called from the format
    /// callback because that is the first moment there is anything to convert
    /// at; after it, `preRollSeconds` is nil and the number is the operator's
    /// for good.
    func settleLegacyPreRoll(atFrameRate frameRate: Double) {
        guard settings.capture.preRollSeconds != nil,
              settings.capture.preRollFrames == nil else { return }
        var capture = settings.capture
        capture.preRollFrames = capture.preRollFramesEffective(
            atFrameRate: frameRate)
        capture.preRollSeconds = nil
        settings.capture = capture
    }
}
