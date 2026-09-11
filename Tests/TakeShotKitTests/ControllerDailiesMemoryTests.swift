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

    /// **The sound folders too**, and re-pointing one keeps its place.
    ///
    /// The recordist's card is set up for the day like the camera's, and the
    /// row's Choose button is how it is followed when it comes back under
    /// another mount point — that button was drawn with an empty action behind
    /// it, so it looked exactly like the sources' one and did nothing at all.
    @Test func theSoundFoldersSurviveTheSheetClosing() async throws {
        try await ControllerHarness.run { controller, root in
            let model = controller.dailies
            model.prepare(takes: [], settings: controller.settings,
                          defaultFolder: root)
            let day = root.appendingPathComponent("SOUND_DAY01", isDirectory: true)
            let moved = root.appendingPathComponent("SOUND_DAY01_2",
                                                    isDirectory: true)
            for folder in [day, moved] {
                try FileManager.default.createDirectory(
                    at: folder, withIntermediateDirectories: true)
            }

            model.addSoundFolder(day)
            controller.debounced.flush(.dailies)
            #expect(controller.settings.dailies.soundPaths?.count == 1,
                    "the sound folder was not remembered")

            // …and the row's Choose button re-points that row in place
            model.replaceSoundFolder(day, with: moved)
            controller.debounced.flush(.dailies)
            #expect(model.soundFolders.map(CaptureController.comparablePath)
                == [CaptureController.comparablePath(moved)],
                "Choose left the row pointing at the folder it replaced")

            let second = DailiesQueueModel()
            second.prepare(takes: [], settings: controller.settings,
                           defaultFolder: root)
            #expect(second.soundFolders.map(CaptureController.comparablePath)
                == [CaptureController.comparablePath(moved)],
                "the sound folder did not come back with the sheet")
        }
    }
}
