import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// **The dailies sheet remembers what was set on it, not just what was RUN.**
///
/// The arrangement used to be written on Start alone, on the argument that a
/// half-set sheet that was never run is not a convention. It is: an operator
/// sets the folders and the switches for the day, shuts the sheet, and comes
/// back to find none of it (owner: "дейлики не сохраняют настройки! ни папку
/// которую я выбирал ни галки, ниче").
@Suite @MainActor struct ControllerDailiesMemoryTests {
    /// Changing a switch on the sheet reaches the stored settings without any
    /// run at all — and comes back on the next `prepare`.
    @Test func aSwitchSetOnTheSheetSurvivesTheSheetClosing() async throws {
        try await ControllerHarness.run { controller, root in
            let model = controller.dailies
            model.prepare(takes: [], settings: controller.settings,
                          defaultFolder: root)
            #expect(model.burnDate == false, "the fixture is not at the default")

            model.burnDate = true
            model.customText = "FOR REVIEW"
            model.datePosition = .topRight
            // the write is debounced: it lands on its own, and the quit guard
            // flushes it — either way it must be there before the sheet is
            // asked to come back
            controller.debounced.flush(.dailies)

            #expect(controller.settings.dailies.burnDate == true,
                    "the switch never reached the settings")
            #expect(controller.settings.dailies.customText == "FOR REVIEW")

            // …and a fresh sheet opens on it
            let second = DailiesQueueModel()
            second.prepare(takes: [], settings: controller.settings,
                           defaultFolder: root)
            #expect(second.burnDate == true)
            #expect(second.customText == "FOR REVIEW")
            #expect(second.datePosition == .topRight)
        }
    }

    /// The folders too — the report named them first ("ни папку которую я
    /// выбирал"), and they are the part that costs real time to set up again.
    @Test func theFoldersSurviveTheSheetClosing() async throws {
        try await ControllerHarness.run { controller, root in
            let model = controller.dailies
            model.prepare(takes: [], settings: controller.settings,
                          defaultFolder: root)
            let card = root.appendingPathComponent("CARD_A", isDirectory: true)
            try FileManager.default.createDirectory(at: card,
                                                    withIntermediateDirectories: true)
            let elsewhere = root.appendingPathComponent("Review", isDirectory: true)
            try FileManager.default.createDirectory(at: elsewhere,
                                                    withIntermediateDirectories: true)

            model.addSource(card)
            model.addDestination(elsewhere)
            controller.debounced.flush(.dailies)

            #expect(controller.settings.dailies.sourcePaths?.count == 1,
                    "the source folder was not remembered")
            let second = DailiesQueueModel()
            second.prepare(takes: [], settings: controller.settings,
                           defaultFolder: root)
            #expect(second.sources.map(CaptureController.comparablePath)
                == [CaptureController.comparablePath(card)])
            #expect(second.destinations.count == 2,
                    "the extra destination was not remembered")
        }
    }
}
