import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// The slate window's model: the card must mirror the naming engine exactly,
/// REC must show the take actually being written, and the sync flash must
/// freeze the click-moment TC honestly — captured at the click, held while the
/// live clock keeps running underneath, released after the hold.
@Suite @MainActor struct SlateModelTests {

    /// The card's fields are the writer's inputs, and the take name is the
    /// naming engine's own answer for them — not a re-implementation that
    /// could drift from what lands on disk.
    @Test func theCardMirrorsWhatTheNextTakeWillBeNamed() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.settings.projectName = "MARS"
            controller.settings.cameraLabel = "B"
            controller.roll = "007" // resets the clip number…
            controller.nextTakeNumber = 12 // …so the clip is set after it

            let slate = controller.slate
            #expect(slate.projectName == "MARS")
            #expect(slate.cameraLabel == "B")
            #expect(slate.roll == "007")
            #expect(slate.clipText == "12")
            #expect(!slate.isRecording)
            // one implementation: the slate shows pendingTakeName itself…
            #expect(slate.takeName == controller.pendingTakeName)
            // …and that name is what the default template produces
            #expect(slate.takeName == "MARS_B007C12")
        }
    }

    /// While a take rolls the card shows the file actually being written and
    /// says REC; after the finalize it moves on to the next name. Driven end
    /// to end through the synthetic backend, like the capture suite.
    @Test func recShowsTheTakeBeingWrittenAndMovesOnAfterIt() async throws {
        try await ControllerHarness.run(live: true) { controller, _ in
            await ControllerWait.until { controller.signalFormat != nil }
            let slate = controller.slate
            // fps on the card is the signal's, as the format badge shows it
            #expect(slate.fpsText == "25")

            controller.toggleManualRecord()
            await ControllerWait.until { controller.isRecording }
            #expect(slate.isRecording)
            let rollingName = slate.takeName

            let deadline = Date().addingTimeInterval(0.8)
            await ControllerWait.until({ Date() >= deadline },
                                       timeout: .seconds(6))
            controller.toggleManualRecord()
            await ControllerWait.untilWritten { controller.takes.count == 1 }

            // the name the slate showed while rolling is the file that landed
            let take = try #require(controller.takes.first)
            #expect(take.url.lastPathComponent == rollingName + ".mov")
            // and afterwards the card is about the NEXT take again
            #expect(!slate.isRecording)
            #expect(slate.takeName == controller.pendingTakeName)
            #expect(slate.takeName != rollingName)
        }
    }

    /// The flash captures the TC of the click moment and holds it on the
    /// readout while the live clock keeps ticking underneath.
    @Test func theSyncFlashFreezesTheClickMomentTimecode() async throws {
        try await ControllerHarness.run { controller, _ in
            let slate = controller.slate
            // the release is not under test here — park it out of reach so a
            // slow machine cannot let it fire mid-assertion
            slate.freezeHold = .seconds(600)
            slate.flashHold = .milliseconds(40)
            let clickMoment = Timecode(hours: 10, minutes: 20, seconds: 30,
                                       frames: 12, fps: 25)
            controller.live.currentTimecode = clickMoment

            slate.fireSync()

            #expect(slate.flashVisible)
            #expect(slate.isFrozen)
            #expect(slate.frozenTimecode == clickMoment)
            #expect(slate.timecodeText == clickMoment.description)

            // the live clock runs on underneath; the hold must not tick
            controller.live.currentTimecode = clickMoment.advanced(by: 25)
            #expect(slate.timecodeText == clickMoment.description,
                    "the hold let the readout tick on")

            // the flash drops on its own, well before the hold does
            let flashDropped = await ControllerWait.until { !slate.flashVisible }
            #expect(flashDropped)
            #expect(slate.isFrozen, "the flash took the hold down with it")
        }
    }

    /// After the hold the readout goes back to the live clock — at whatever
    /// the clock says NOW, not where it was frozen.
    @Test func theFrozenTimecodeReleasesBackToTheLiveClock() async throws {
        try await ControllerHarness.run { controller, _ in
            let slate = controller.slate
            slate.freezeHold = .milliseconds(150)
            let clickMoment = Timecode(hours: 11, minutes: 0, seconds: 0,
                                       frames: 0, fps: 25)
            controller.live.currentTimecode = clickMoment
            slate.fireSync()

            let released = await ControllerWait.until { !slate.isFrozen }

            #expect(released, "the hold never released")
            #expect(slate.frozenTimecode == nil)
            // The clock is set AFTER the release poll, in the same MainActor
            // turn as the assertion: the harness's stopCapture posts a nil TC
            // asynchronously, and a value set before the wait can be wiped by
            // it mid-poll. What is under test is only that the readout follows
            // the live clock again once the hold is over.
            let later = clickMoment.advanced(by: 50)
            controller.live.currentTimecode = later
            #expect(slate.timecodeText == later.description)
        }
    }

    /// A second click mid-hold is a NEW sync point: it recaptures and the
    /// previous release must not cut the fresh hold short.
    @Test func aSecondSyncMidHoldRecapturesTheNewMoment() async throws {
        try await ControllerHarness.run { controller, _ in
            let slate = controller.slate
            slate.freezeHold = .seconds(600)
            let first = Timecode(hours: 12, minutes: 0, seconds: 0,
                                 frames: 0, fps: 25)
            controller.live.currentTimecode = first
            slate.fireSync()

            let second = first.advanced(by: 100)
            controller.live.currentTimecode = second
            slate.fireSync()

            #expect(slate.isFrozen)
            #expect(slate.frozenTimecode == second)
            #expect(slate.timecodeText == second.description)
        }
    }

    /// With no signal the readout shows the badge's own fallback — and a sync
    /// fired then holds that fallback, never a stale number.
    @Test func withNoSignalTheReadoutShowsTheBadgesFallback() async throws {
        try await ControllerHarness.run { controller, _ in
            let slate = controller.slate
            slate.freezeHold = .seconds(600)
            controller.live.currentTimecode = nil

            #expect(slate.timecodeText == timecodeFallbackText)
            #expect(slate.fpsText == nil)

            slate.fireSync()
            #expect(slate.flashVisible)
            #expect(slate.timecodeText == timecodeFallbackText)
        }
    }
}
