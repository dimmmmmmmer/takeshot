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
            model.goodTakesOnly = true
            model.skipFinished = false
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
            #expect(second.goodTakesOnly, """
                the circled-takes filter did not come back with the sheet
                """)
            // This one is ON by default, so it is the OFF state that has to
            // survive — a flag whose nil means true is the easy one to store
            // backwards.
            #expect(!second.skipFinished, """
                the skip switch came back on after being turned off
                """)
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

    // MARK: - the circled-takes filter

    /// **"Only the circled takes" narrows the run itself**, not just a label
    /// (owner: "давай еще сделаем галку где-нибудь типа рендерить только
    /// удачные тейки").
    ///
    /// The count on the button, the preview's frame and what Start renders all
    /// come from `queueContents`, so this asks the funnel rather than the flag:
    /// a filter applied at two of the three is how a sheet promises a different
    /// run from the one it makes.
    @Test func theCircledFilterNarrowsWhatTheRunIsMadeOf() async throws {
        try await ControllerHarness.run { controller, root in
            var takes = ["A001C01", "A001C02", "A001C03"].map {
                ControllerFixtures.take(named: $0, in: root)
            }
            takes[1].rating = .good
            controller.takes = takes
            controller.showDailiesSheet()
            let model = controller.dailies
            #expect(model.itemCount == 3, "the whole day is the default")

            model.goodTakesOnly = true
            #expect(model.itemCount == 1, """
                the filter left \(model.itemCount) items — one take is circled
                """)
            guard case .takes(let queued) = model.queueContents else {
                Issue.record("the queue is not made of takes")
                return
            }
            #expect(queued.map(\.url) == [takes[1].url], """
                the queue holds \(queued.map(\.url.lastPathComponent))
                """)
            #expect(model.plannedItems(settings: controller.settings).count == 1)
        }
    }

    /// …and the switch greys for a run from SOURCE FOLDERS, because a clip on
    /// a card has no rating to be circled — the ratings are this app's own
    /// takes'. A switch that narrows nothing is worse than one that is off.
    @Test func theCircledFilterIsGreyedForACardRun() async throws {
        try await ControllerHarness.run { controller, root in
            controller.showDailiesSheet()
            #expect(controller.canFilterDailiesToGoodTakes)
            let card = root.appendingPathComponent("CARD_A", isDirectory: true)
            try FileManager.default.createDirectory(
                at: card, withIntermediateDirectories: true)
            controller.dailies.addSource(card)
            #expect(!controller.canFilterDailiesToGoodTakes, """
                the circled filter is offered for a run made of card clips
                """)
        }
    }

    /// The sheet can export the day's timeline, and says so only when there is
    /// one (owner: "чтоб можно было сразу с этой странички дейликов
    /// экспортнуть таймлайн с удачными тейками").
    @Test func theTimelineExportIsOfferedOnlyWithCircledTakes() async throws {
        try await ControllerHarness.run { controller, root in
            var takes = [ControllerFixtures.take(named: "A001C01", in: root)]
            controller.takes = takes
            #expect(!controller.canExportDailiesTimeline,
                    "a timeline was offered with nothing circled in the day")
            takes[0].rating = .good
            controller.takes = takes
            #expect(controller.canExportDailiesTimeline)
        }
    }

    /// **The sheet can check its own destination** (owner: "ну и чтобы
    /// какая-то у нас проверка типа как после копий была что все файлы точно
    /// отрендерены как надо") — and it answers about the FOLDER, which
    /// includes runs from other days.
    @Test func theSheetChecksWhatTheFolderHolds() async throws {
        try await ControllerHarness.run { controller, root in
            let model = controller.dailies
            model.prepare(takes: [], settings: controller.settings,
                          defaultFolder: root)
            #expect(controller.canVerifyDailies)
            #expect(model.verifyFindings.isEmpty)

            model.verifyDestination()
            // The wait ANSWERS, and the answer is the assertion — `try` on a
            // call that cannot throw is a warning, and CI's build gate is
            // warning-free.
            #expect(await ControllerWait.until { !model.isVerifying },
                    "the check never finished")
            // An empty folder has nothing to report and is not a fault: the
            // journal is the list, and there is no journal yet.
            #expect(model.verifyFindings.isEmpty)
            #expect(controller.lastNotice == L("dailies_verify_empty"))

            // A journal naming a file that is not there is exactly the case
            // an operator runs this for.
            var journal = DailiesJournal()
            journal.record(DailiesJournal.Entry(
                source: "A001C01.mov", sourceSize: 1, sourceModified: Date(),
                recipe: "r", output: "A001C01_DAILY.mov", outputSize: 2,
                finishedAt: Date()))
            try DailiesProgressJournal.write(journal, into: root)

            model.verifyDestination()
            #expect(await ControllerWait.until { !model.isVerifying },
                    "the check never finished")
            #expect(model.verifyFindings.map(\.verdict) == [.missing])
            #expect(controller.lastError?.isEmpty == false, """
                a missing daily did not reach the operator
                """)
        }
    }
}
