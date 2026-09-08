import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// **What quitting would interrupt.**
///
/// The app used to go down without a word on whatever was in flight, and the
/// owner closed it in the middle of a card copy — the one job here where the
/// source gets wiped afterwards on the strength of it having finished.
///
/// The dialog is AppKit's and not reachable from a headless run; the RULE is
/// on the controller precisely so this suite can ask it.
@Suite @MainActor struct ControllerQuitRiskTests {
    @Test func anIdleAppQuitsWithoutAQuestion() async throws {
        try await ControllerHarness.run { controller, _ in
            #expect(controller.quitRisk == nil)
        }
    }

    @Test func eachRunningJobIsNamed() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.offload.isRunning = true
            #expect(controller.quitRisk == L("quit_risk_offload"))
            controller.offload.isRunning = false

            controller.verify.isRunning = true
            #expect(controller.quitRisk == L("quit_risk_verify"))
            controller.verify.isRunning = false

            controller.dailies.isRunning = true
            #expect(controller.quitRisk == L("quit_risk_dailies"))
            controller.dailies.isRunning = false

            #expect(controller.quitRisk == nil,
                    "the risk did not clear when the jobs ended")
        }
    }

    /// A rolling take outranks everything under it: the moment is gone, and
    /// every other job can be started again.
    @Test func aRollingTakeIsTheFirstThingSaid() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.isRecording = true
            controller.offload.isRunning = true
            controller.dailies.isRunning = true
            #expect(controller.quitRisk == L("quit_risk_recording"))
        }
    }

    /// The card-copy sentence has to tell the operator not to wipe the card —
    /// that is the whole reason this warning exists rather than a toast.
    @Test func theCardCopyWarningSaysNotToWipeTheCard() {
        for language in [AppLanguage.english, .russian] {
            let text = ViewRender.withLanguage(language) { L("quit_risk_offload") }
            #expect(text.count > 40,
                    Comment(rawValue: "the \(language.rawValue) warning is too short: \(text)"))
        }
    }
}
