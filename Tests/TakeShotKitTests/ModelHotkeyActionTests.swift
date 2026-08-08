import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// What a bound key actually DOES.
///
/// The combos, their persistence and their conflicts are pinned next door in
/// `ModelHotkeyTests`; the fan-out that turns one into an action was never run.
/// It is a fourteen-arm switch over an enum, which is exactly the shape that
/// silently binds two keys to the same thing — and on set the keyboard is how
/// REC gets pressed when the operator is not looking at the screen.
///
/// Every arm is asserted through the state the on-screen button changes, never
/// through the manager, because "the key and the button do the same thing" is
/// the only property worth having here.
@Suite @MainActor struct ModelHotkeyActionTests {
    /// Never the operator's real bindings: `HotkeyManager` reads and writes
    /// `UserDefaults` under a key of its own.
    private func manager() -> HotkeyManager {
        HotkeyManager(defaults: InMemoryDefaults())
    }

    private func seedTake(_ controller: CaptureController, in root: URL,
                          named name: String) throws -> Take {
        let take = ControllerFixtures.take(named: name, in: root)
        try ControllerFixtures.placeholder(for: take)
        controller.takes.append(take)
        return take
    }

    // MARK: - the red button

    /// REC is refused when there is nothing to record. Without the guard the
    /// key opens a writer against no signal, and the take that comes out has no
    /// frames in it.
    @Test func theRecordKeyIsRefusedWhenNothingIsCapturing() async throws {
        try await ControllerHarness.run { controller, _ in
            try #require(!controller.isCapturing)

            manager().perform(.toggleRecord, controller: controller)

            #expect(!controller.isRecording)
            #expect(!controller.pipeline.health.isRecording)
        }
    }

    /// …and rolls one when there is. The same method the red button calls, so
    /// the take is indistinguishable from a take started by hand.
    @Test func theRecordKeyRollsAndClosesATake() async throws {
        try await ControllerHarness.run(live: true) { controller, _ in
            let hotkeys = manager()
            #expect(await ControllerWait.until { controller.signalFormat != nil })

            hotkeys.perform(.toggleRecord, controller: controller)
            #expect(await ControllerWait.until { controller.isRecording })

            hotkeys.perform(.toggleRecord, controller: controller)
            #expect(await ControllerWait.untilWritten { !controller.isRecording })
            #expect(await ControllerWait.untilWritten { controller.takes.count == 1 })
        }
    }

    // MARK: - the take list

    /// The two rating keys mark the take that just finished — the gesture an
    /// operator makes without looking away from the camera — and each one
    /// toggles its OWN rating off rather than clearing whatever is there.
    @Test func theRatingKeysMarkAndUnmarkTheLastTake() async throws {
        try await ControllerHarness.run { controller, root in
            let hotkeys = manager()
            _ = try seedTake(controller, in: root, named: "A001C01")
            _ = try seedTake(controller, in: root, named: "A001C02")

            hotkeys.perform(.circleLastTake, controller: controller)
            #expect(controller.takes.last?.rating == .good)
            #expect(controller.takes.first?.rating == TakeRating.none,
                    "the rating key reached a take that was not the last one")

            hotkeys.perform(.circleLastTake, controller: controller)
            #expect(controller.takes.last?.rating == TakeRating.none)

            hotkeys.perform(.badTakeLast, controller: controller)
            #expect(controller.takes.last?.rating == .bad)
            hotkeys.perform(.circleLastTake, controller: controller)
            #expect(controller.takes.last?.rating == .good,
                    "the two rating keys did not replace one another")
        }
    }

    // MARK: - the viewer

    /// Four viewer keys, four different controls. Asserted one at a time
    /// against the rest of the vector: a key that reached a second control as
    /// well would be invisible to a test that only looked at its own.
    @Test func eachViewerKeyReachesItsOwnControlAndNoOther() async throws {
        try await ControllerHarness.run { controller, _ in
            let hotkeys = manager()
            try #require(!controller.showScopesOverlay)
            try #require(controller.viewerMode == .record)
            try #require(controller.liveAssist.punchIn == 1)

            hotkeys.perform(.toggleScopesOverlay, controller: controller)
            #expect(controller.showScopesOverlay)
            #expect(controller.viewerMode == .record)
            #expect(controller.liveAssist.punchIn == 1)

            hotkeys.perform(.punchIn, controller: controller)
            #expect(controller.liveAssist.punchIn > 1)
            hotkeys.perform(.punchIn, controller: controller)
            #expect(controller.liveAssist.punchIn == 1,
                    "the punch-in key did not come back out")

            hotkeys.perform(.toggleViewerMode, controller: controller)
            #expect(controller.viewerMode == .playback)
            hotkeys.perform(.toggleViewerMode, controller: controller)
            #expect(controller.viewerMode == .record)
        }
    }

    /// The LUT key is disabled by the same condition the LUT menu's item is: a
    /// state that reads "LUT on" with no LUT loaded looks like a broken LUT.
    @Test func theLUTKeyDoesNothingUntilThereIsALUTToApply() async throws {
        try await ControllerHarness.run { controller, _ in
            let hotkeys = manager()
            try #require(controller.settings.lutFileName == nil)
            let before = controller.lutPreviewOn

            hotkeys.perform(.toggleLUTPreview, controller: controller)
            #expect(controller.lutPreviewOn == before,
                    "the LUT preview came on with no LUT selected")

            controller.settings.lutFileName = "something.cube"
            hotkeys.perform(.toggleLUTPreview, controller: controller)
            #expect(controller.lutPreviewOn != before)
        }
    }

    // MARK: - what the operator hears, and what gets recorded of it

    /// Mute engages from the key exactly as it does from the footer speaker.
    ///
    /// Only the muting direction: un-muting means "I want to hear it" and
    /// switches the live monitor back on, which in a test would open an output
    /// device on the machine running the suite.
    @Test func theMuteKeyEngagesTheSameHoldTheSpeakerButtonDoes() async throws {
        try await ControllerHarness.run { controller, _ in
            try #require(!controller.live.muted)

            manager().perform(.toggleMonitorMute, controller: controller)

            #expect(controller.live.muted)
            #expect(controller.live.volume == 0)
            #expect(!controller.monitorOn, "the mute key switched the monitor on")
        }
    }

    /// DIM is refused when it would be holding nothing down — the condition the
    /// footer's DIM button is disabled by. A dim engaged over silence lies
    /// about the level the operator is hearing.
    @Test func theDimKeyIsRefusedWhenThereIsNothingToHoldDown() async throws {
        try await ControllerHarness.run { controller, _ in
            try #require(!controller.canDimMonitoring)

            manager().perform(.toggleMonitorDim, controller: controller)

            #expect(!controller.live.dimmed)
        }
    }

    /// The channel-bank key drops the recording to the mix pair and puts the
    /// previous mask back, and it is refused mid-take for the reason the
    /// panel's channel columns are: the mask is latched per take, so a change
    /// that looks applied would desync the file from the meters.
    @Test func theChannelBankKeySwitchesToTheMixAndBack() async throws {
        try await ControllerHarness.run { controller, _ in
            let hotkeys = manager()
            try #require(controller.settings.audioChannelMask == nil)

            hotkeys.perform(.toggleAudioChannelBank, controller: controller)
            #expect(controller.settings.audioChannelMask
                == CaptureController.mixChannelMask)
            #expect(controller.isRecordingMixOnly)

            hotkeys.perform(.toggleAudioChannelBank, controller: controller)
            #expect(controller.settings.audioChannelMask == nil,
                    "the previous channel mask did not come back")
        }
    }

    @Test func theChannelBankKeyIsRefusedWhileATakeIsRolling() async throws {
        try await ControllerHarness.run(live: true) { controller, _ in
            let hotkeys = manager()
            #expect(await ControllerWait.until { controller.signalFormat != nil })
            controller.toggleManualRecord()
            #expect(await ControllerWait.until { controller.isRecording })
            let latched = controller.settings.audioChannelMask

            hotkeys.perform(.toggleAudioChannelBank, controller: controller)

            #expect(controller.settings.audioChannelMask == latched,
                    "the channel mask moved under a rolling take")

            controller.toggleManualRecord()
            #expect(await ControllerWait.untilWritten { !controller.isRecording })
        }
    }

    // MARK: - markers

    /// The marker keys act on the take in progress, which is when an operator
    /// actually presses them — a note on the good bit, made while it happens.
    @Test func theMarkerKeysAnnotateTheTakeInProgress() async throws {
        try await ControllerHarness.run(live: true) { controller, _ in
            let hotkeys = manager()
            #expect(await ControllerWait.until { controller.signalFormat != nil })
            controller.toggleManualRecord()
            #expect(await ControllerWait.until { controller.isRecording })

            hotkeys.perform(.addMarker, controller: controller)
            #expect(controller.recordingMarkers.count == 1)

            hotkeys.perform(.removeMarker, controller: controller)
            #expect(controller.recordingMarkers.isEmpty)

            controller.toggleManualRecord()
            #expect(await ControllerWait.untilWritten { !controller.isRecording })
        }
    }

    // MARK: - the two that only report

    /// A grab with no picture to grab, and a replay with nothing to replay.
    /// Both are reachable by keyboard at any moment, so both have to come back
    /// rather than act on nothing.
    @Test func theGrabAndReplayKeysAreSafeWithNothingToActOn() async throws {
        try await ControllerHarness.run { controller, root in
            let hotkeys = manager()

            hotkeys.perform(.grabFrame, controller: controller)
            hotkeys.perform(.instantReplay, controller: controller)

            #expect(controller.takes.isEmpty)
            let written = try FileManager.default
                .contentsOfDirectory(atPath: root.path)
                .filter { $0.hasSuffix(".png") || $0.hasSuffix(".tif") }
            #expect(written.isEmpty, "a grab with no signal wrote \(written)")
        }
    }
}
