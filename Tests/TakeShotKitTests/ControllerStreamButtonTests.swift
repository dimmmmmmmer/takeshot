import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// **The footer's stream button starts as well as stops** (owner: "должна быть
/// кнопка запустить/остановить поток" — two words, and only one of them was
/// built).
///
/// The first version was a one-way door: one press turned both switches off,
/// the indicator's `isEngaged` went false, the control erased itself, and the
/// only way to stream again was the Settings window — the window the indicator
/// exists so nobody has to open during a shooting day. There was no test on
/// this path at all, which is how it shipped.
@Suite @MainActor struct ControllerStreamButtonTests {
    @Test func aPressStopsBothAndTheNextPressStartsThemAgain() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.settings.srt.enabled = true
            controller.settings.ndi.enabled = true

            controller.stopAllStreams()
            #expect(controller.settings.srt.enabled == false)
            #expect(controller.settings.ndi.enabled == false)
            #expect(controller.mirrors.pausedStreams.any,
                    "nothing remembered what was switched off")

            controller.resumeStreams()
            #expect(controller.settings.srt.enabled == true,
                    "SRT did not come back — the button is still a one-way door")
            #expect(controller.settings.ndi.enabled == true)
            #expect(!controller.mirrors.pausedStreams.any,
                    "the pause record outlived the resume")
        }
    }

    /// Exactly what was paused, and nothing else. An operator who took NDI off
    /// the set network before the shoot has not asked for it back, and a button
    /// that decided otherwise would put a picture on that network again.
    @Test func onlyWhatThisButtonStoppedComesBack() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.settings.srt.enabled = true
            controller.settings.ndi.enabled = false  // a decision, not a pause

            controller.stopAllStreams()
            #expect(controller.mirrors.pausedStreams.srt)
            #expect(!controller.mirrors.pausedStreams.ndi)

            controller.resumeStreams()
            #expect(controller.settings.srt.enabled == true)
            #expect(controller.settings.ndi.enabled == false,
                    "a stream switched off in Settings was turned back on")
        }
    }

    /// A second press on an already-stopped footer must not erase what the
    /// first one remembered.
    @Test func aPressWithNothingRunningKeepsTheRecord() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.settings.srt.enabled = true
            controller.stopAllStreams()
            controller.stopAllStreams()
            #expect(controller.mirrors.pausedStreams.srt,
                    "the second press wiped what the first one paused")

            controller.resumeStreams()
            #expect(controller.settings.srt.enabled == true)
        }
    }

    /// And a resume with nothing paused does nothing at all — the button is not
    /// a way to turn on a stream that was never running.
    @Test func aResumeWithNothingPausedTurnsNothingOn() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.settings.srt.enabled = false
            controller.settings.ndi.enabled = false
            controller.resumeStreams()
            #expect(controller.settings.srt.enabled == false)
            #expect(controller.settings.ndi.enabled == false)
        }
    }
}
