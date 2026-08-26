import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// The pre-roll as the operator meets it: two units over one stored number.
///
/// The unit is a preference about the FIELD, and the whole risk in offering one
/// is that it becomes a second answer — a seconds value that disagrees with the
/// frame count, or that reaches the ring past a bound stated in frames. Every
/// test here is about the two units meeting the same number.
@MainActor
struct ControllerPreRollTests {
    @Test func theUnitSwitchNeverChangesTheStoredFrameCount() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.preRollFrames = 12
            for unit: PreRollUnit in [.seconds, .frames, .seconds] {
                controller.preRollUnit = unit
                #expect(controller.settings.capture.preRollFrames == 12,
                        "switching to \(unit.rawValue) moved the pre-roll")
            }
            #expect(controller.settings.capture.preRollUnit == "seconds",
                    "the operator's choice of unit was not kept")
        }
    }

    /// A seconds entry is stored as frames at the signal's rate and nowhere
    /// else — there is no seconds field on the record for the two to disagree
    /// through, and the readout comes back off the frame count.
    @Test func aSecondsEntryIsStoredAsFramesAndNothingElse() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.signalFormat = CaptureFormat(
                width: 1920, height: 1080, frameRate: 50, timecodeFPS: 50,
                name: "1080p50")
            controller.preRollSecondsEntry = 1.5
            #expect(controller.settings.capture.preRollFrames == 75,
                    "1.5 s at 50 fps is 75 frames")
            #expect(controller.settings.capture.preRollSeconds == nil,
                    "a seconds value was stored beside the frame count")
            #expect(controller.preRollSecondsEntry == 1.5,
                    "the field does not read back what was typed into it")
        }
    }

    /// The frame count is the stored truth, so the seconds READING moves when
    /// the signal changes and the frame count does not. That is the pairing the
    /// readout exists to make visible.
    @Test func aRateChangeMovesTheSecondsReadingAndNotTheFrames() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.signalFormat = CaptureFormat(
                width: 1920, height: 1080, frameRate: 25, timecodeFPS: 25,
                name: "1080p25")
            controller.preRollSecondsEntry = 2
            #expect(controller.preRollFrames == 50)

            controller.signalFormat = CaptureFormat(
                width: 1920, height: 1080, frameRate: 50, timecodeFPS: 50,
                name: "1080p50")
            #expect(controller.preRollFrames == 50,
                    "the stored frame count followed the signal")
            #expect(controller.preRollSecondsEntry == 1,
                    "50 frames at 50 fps is 1 s")
        }
    }

    /// A seconds entry cannot ask for more pre-roll than the frames field can,
    /// because it becomes a frame count before anything is stored. The ring's
    /// memory ceiling is stated in frames and this is the obvious way around it.
    @Test func aHugeSecondsEntryIsHeldToTheSameMaximumAsFrames() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.signalFormat = CaptureFormat(
                width: 1920, height: 1080, frameRate: 50, timecodeFPS: 50,
                name: "1080p50")
            controller.preRollSecondsEntry = 600
            let ceiling: Int = CaptureSignalSettings.preRollFrameRange.upperBound
            #expect(controller.preRollFrames == ceiling,
                    "600 s became \(controller.preRollFrames) frames")
            #expect(controller.preRollSecondsEntry == 2,
                    "the field shows what was really kept, not what was typed")
        }
    }

    /// The readout carries both numbers and the rate they were converted at,
    /// and says so when there is no signal and the rate is an assumption rather
    /// than a measurement.
    @Test func theReadoutShowsBothUnitsAndWhereTheRateCameFrom() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.signalFormat = nil
            controller.preRollFrames = 12
            let assumed: String = controller.preRollReading
            #expect(assumed.contains("12"), "no frame count in \(assumed)")
            #expect(assumed.contains("0.48"), "no seconds reading in \(assumed)")
            #expect(assumed.contains("25"), "no rate in \(assumed)")

            controller.signalFormat = CaptureFormat(
                width: 1920, height: 1080, frameRate: 24, timecodeFPS: 24,
                name: "1080p24")
            let measured: String = controller.preRollReading
            #expect(measured.contains("0.50"), "12 frames at 24 fps is 0.50 s")
            #expect(measured != assumed,
                    "the readout says the same thing with and without a signal")
        }
    }

    /// A LEGACY seconds pre-roll is settled into frames the first time a real
    /// rate is known — once. Without it the value would be re-derived on every
    /// read and would MOVE when the camera changed rate, which is the one thing
    /// storing a frame count exists to prevent.
    @Test func aLegacySecondsPreRollIsSettledOnceTheSignalIsUp() async throws {
        try await ControllerHarness.run { controller, _ in
            // the shape an old settings blob decodes into: seconds, no frames
            controller.settings.capture.preRollFrames = nil
            controller.settings.capture.preRollSeconds = 1

            controller.settleLegacyPreRoll(atFrameRate: 50)
            #expect(controller.settings.capture.preRollFrames == 50,
                    "one second at 50 fps did not settle as 50 frames")
            #expect(controller.settings.capture.preRollSeconds == nil,
                    "the legacy value is still on the record")

            // …and a later rate cannot move it
            controller.settleLegacyPreRoll(atFrameRate: 24)
            #expect(controller.settings.capture.preRollFrames == 50,
                    "the settled frame count followed a later rate")
        }
    }
}
