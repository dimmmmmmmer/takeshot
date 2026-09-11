import AVFoundation
import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// The dailies queue as the app runs it: seeded from the takes panel, driven
/// through the controller-owned model, and — the hard rule — paused by the
/// recording state and resumed when the take ends. Everything polls outcomes
/// with I/O-sized budgets; nothing waits on the wall clock.
@Suite @MainActor struct ControllerDailiesTests {
    /// A take backed by a real playable file, written by the app's own writer.
    private func recordedTake(named name: String, in folder: URL,
                              frames: Int = 50) async throws -> Take {
        let url = try await MediaFixtures.writeClip(
            at: folder.appendingPathComponent("\(name).mov"), frames: frames)
        return Take(url: url, scene: "", roll: "001", takeNumber: 1,
                    startTimecode: MediaFixtures.startTimecode,
                    durationSeconds: Double(frames) / 25, recordedAt: Date())
    }

    /// **The preview describes the queue the run will actually make.**
    ///
    /// Both halves of one report (owner: "при обновлении папки сорсов превью
    /// не обновляется и не подгоняется вся новая инфа под новое превью"): the
    /// frame the strips are laid over, and the strips themselves.
    ///
    /// The frame used to be taken once, when the sheet opened, from the day's
    /// TAKES — footage a run made from a card does not touch — and the strips
    /// described a made-up take whatever was queued. This asks for both with
    /// no thumbnails cached at all, so a frame that arrives can ONLY have come
    /// from the card: the take path answers nil by construction here.
    @Test func thePreviewFollowsTheSourceFolder() async throws {
        try await ControllerHarness.run { controller, root in
            let card = try MediaFixtures.makeDirectory("dailies-card")
            defer { try? FileManager.default.removeItem(at: card) }
            _ = try await MediaFixtures.writeClip(
                at: card.appendingPathComponent("C0007.mov"), frames: 8)

            let take = try await self.recordedTake(named: "A001C001", in: root)
            // In the LIST, not just handed to `prepare`: opening the sheet
            // re-seeds the queue from `dailiesCandidates`, which is the panel's
            // selection or the day's takes.
            controller.takes = [take]
            let model = controller.dailies
            controller.showDailiesSheet()
            try #require(controller.thumbnails.isEmpty,
                         "a cached thumbnail would make the frame ambiguous")
            try #require(model.previewStill == nil,
                         "there is a frame already, so nothing below is proof")
            #expect(model.previewItem?.clipName == "A001C001",
                    "the preview does not describe the day's own take")

            model.addSource(card)
            #expect(await ControllerWait.until { !model.isScanning })
            #expect(model.previewItem?.clipName == "C0007",
                    "the strips still describe a take the run will not touch")
            #expect(await ControllerWait.until { model.previewStill != nil }, """
                the preview's frame never came from the card — it is still \
                whatever the sheet was opened with
                """)

            // …and taking the card off puts the queue, and the strips, back.
            model.removeSource(card)
            #expect(await ControllerWait.until { !model.isScanning })
            #expect(model.previewItem?.clipName == "A001C001")
        }
    }

    /// A rescan clears what it is about to replace, so nothing reads the
    /// PREVIOUS card's answer while the walk runs. Asserted synchronously
    /// right after the call, which is the only moment the old value could
    /// still be there.
    @Test func pointingAtAnotherCardDoesNotLeaveTheOldCount() async throws {
        try await ControllerHarness.run { controller, root in
            let first = try MediaFixtures.makeDirectory("dailies-card-1")
            let second = try MediaFixtures.makeDirectory("dailies-card-2")
            defer {
                try? FileManager.default.removeItem(at: first)
                try? FileManager.default.removeItem(at: second)
            }
            for name in ["C0001.mov", "C0002.mov"] {
                try Data([0]).write(to: first.appendingPathComponent(name))
            }
            try Data([0]).write(to: second.appendingPathComponent("C0009.mov"))

            let model = controller.dailies
            model.prepare(takes: [], settings: controller.settings,
                          defaultFolder: root)
            model.addSource(first)
            #expect(await ControllerWait.until { !model.isScanning })
            try #require(model.itemCount == 2, "the first card never landed")

            // A card ADDED to the list, not one swapped for it: emptying the
            // list has always cleared the findings, so a removal proves
            // nothing about the walk.
            model.addSource(second)
            #expect(model.itemCount == 0, """
                the sheet still says \(model.itemCount) — that is the previous \
                card's count, standing while the new walk runs
                """)
            #expect(await ControllerWait.until { model.itemCount == 3 })
        }
    }

    /// Recording protection, end to end through the mock backend: a queue
    /// started while a take rolls holds at zero frames, and REC stop is what
    /// releases it — no operator action, no sheet on screen.
    @Test func recordingPausesTheQueueAndStoppingRecordingResumesIt() async throws {
        try await ControllerHarness.run(live: true) { controller, _ in
            await ControllerWait.until { controller.signalFormat != nil }
            let media = try MediaFixtures.makeDirectory("dailies-sources")
            defer { try? FileManager.default.removeItem(at: media) }
            let takes = [try await recordedTake(named: "one", in: media),
                         try await recordedTake(named: "two", in: media)]
            let dailiesFolder = media.appendingPathComponent("Dailies")

            controller.toggleManualRecord()
            await ControllerWait.until { controller.isRecording }

            controller.dailies.prepare(takes: takes,
                                       settings: controller.settings,
                                       defaultFolder: dailiesFolder)
            controller.dailies.start()
            #expect(controller.dailies.isRunning)

            // The engine reports the hold itself — paused, zero frames done.
            await ControllerWait.untilWritten {
                controller.dailies.progress?.isPaused == true
            }
            #expect(controller.dailies.progress?.isPaused == true,
                    "the queue never paused while recording")
            #expect(controller.dailies.progress?.framesDone == 0)
            #expect(controller.dailiesStatus == L("dailies_paused_rec"))
            // …and stays held: a full-budget wait proving frames do NOT move
            // (the harness's own idiom for asserting the negative).
            let moved = await ControllerWait.until(
                { (controller.dailies.progress?.framesDone ?? 0) > 0 },
                timeout: .seconds(2))
            #expect(!moved, "the queue transcoded while the app was recording")

            controller.toggleManualRecord()
            await ControllerWait.until { !controller.isRecording }

            // REC stop is the release: the whole batch now runs to the end.
            await ControllerWait.untilWritten {
                controller.dailies.report != nil
            }
            let report = try #require(controller.dailies.report)
            #expect(report.isFullySucceeded,
                    "items failed: \(report.failed)")
            for name in ["one_DAILY.mp4", "two_DAILY.mp4"] {
                #expect(FileManager.default.fileExists(
                    atPath: dailiesFolder.appendingPathComponent(name).path),
                    "\(name) is missing")
            }
            #expect(controller.dailiesStatus == nil)
            // A PHRASE and not a number: the sentence takes a counted noun
            // now, because "2 файлов" was wrong in Russian for every count
            // between one and four. See `CountedNoun`.
            #expect(controller.lastNotice
                    == L("dailies_done", localizedCount(2, .file)))
        }
    }

    /// The sheet's batch: the panel selection when there is one, the whole
    /// day when there is not — and Other content never qualifies.
    @Test func theSheetSeedsTheSelectionElseTheWholeDay() async throws {
        try await ControllerHarness.run { controller, root in
            let takes = ["A001C01", "A001C02", "A001C03"].map {
                ControllerFixtures.take(named: $0, in: root)
            }
            controller.takes = takes
            controller.selectedItems = [takes[1].url,
                                        root.appendingPathComponent("stray.mp4")]

            controller.showDailiesSheet()
            #expect(controller.dailiesSheetPresented)
            #expect(controller.dailies.queuedTakes.map(\.url) == [takes[1].url])
            // the default destination is a Dailies folder beside the takes
            #expect(controller.dailies.destination?.path
                == root.appendingPathComponent("Dailies").path)

            controller.dailiesSheetPresented = false
            controller.selectedItems = []
            controller.showDailiesSheet()
            #expect(controller.dailies.queuedTakes.count == takes.count)
        }
    }

    /// The burn-in convention persists like every other setting: written on
    /// Start (via `rememberDailiesChoices`), decodable from the stored blob,
    /// and seeded back into the next sheet.
    @Test func burninChoicesPersistLikeOtherSettings() async throws {
        try await ControllerHarness.run { controller, root in
            let model = controller.dailies
            model.prepare(takes: [], settings: controller.settings,
                          defaultFolder: root.appendingPathComponent("Dailies"))
            #expect(model.burnTimecode && model.burnClipName
                && model.burnProject && !model.burnDate)

            model.burnTimecode = false
            model.burnDate = true
            model.bakeLook = true
            // …and the squeeze, which travels the same way: the operator's own
            // factor read on this side and handed to the run.
            controller.settings.assist.desqueezeOn = true
            controller.settings.assist.desqueezeFactor = 2
            model.bakeDesqueeze = true
            model.customText = "  FOR REVIEW  "
            let elsewhere = root.appendingPathComponent("Elsewhere")
            model.destination = elsewhere
            controller.rememberDailiesChoices(from: model)

            // through the JSON blob, exactly as a relaunch would read it
            let reloaded = CaptureSettings.loaded(from: controller.defaults)
            #expect(reloaded.dailies.burnTimecode == false)
            #expect(reloaded.dailies.burnDate == true)
            #expect(reloaded.dailies.customText == "FOR REVIEW")
            // …and OFF is written as nothing at all, so an older build's blob
            // still decodes and a daily is never silently graded.
            #expect(reloaded.dailies.bakeLook == true)
            #expect(DailiesSettings().bakeLook == nil,
                    "baking a look is on by default")
            #expect(reloaded.dailies.destinationPath == elsewhere.path)

            // …and the next sheet opens on the saved convention
            model.prepare(takes: [], settings: reloaded,
                          defaultFolder: root.appendingPathComponent("Dailies"))
            #expect(!model.burnTimecode)
            #expect(model.burnDate)
            #expect(model.customText == "FOR REVIEW")
            #expect(model.bakeLook, "the look switch did not survive the blob")
            #expect(model.destination?.path == elsewhere.path)
        }
    }

    /// The destination can be given back.
    ///
    /// It could not be, and the consequence outlived the day: `destinationPath`
    /// had no writer that could produce nil, so the first run pinned the
    /// deliverable to one absolute path — and the record folder is re-pointed
    /// between shows, so the next show's dailies went on landing on the last
    /// show's disk with no control anywhere to say otherwise.
    ///
    /// Three halves, and all three are needed: the minus clears the stored
    /// override, the model goes back to the folder beside the footage, and a
    /// run into that folder does NOT store it again.
    @Test func theDailiesDestinationCanBeReturnedToTheFolderBesideTheFootage() async throws {
        try await ControllerHarness.run { controller, root in
            let model: DailiesQueueModel = controller.dailies
            let beside: URL = controller.defaultDailiesFolder
            model.prepare(takes: [], settings: controller.settings,
                          defaultFolder: beside)
            #expect(model.destination?.path == beside.path,
                    "the default is not the default")
            #expect(model.isDestinationDefault)
            #expect(!controller.canClearDailiesDestination,
                    "the minus offers to undo a choice nobody made")

            let ssd: URL = root.appendingPathComponent("DAILIES_SSD/Review")
            model.destination = ssd
            controller.rememberDailiesChoices(from: model)
            #expect(controller.settings.dailies.destinationPath == ssd.path)
            #expect(controller.canClearDailiesDestination)

            controller.clearDailiesDestination()

            #expect(controller.settings.dailies.destinationPath == nil,
                    "the stored override survived the minus")
            #expect(model.destination?.path == beside.path,
                    "the sheet did not go back to the folder beside the footage")
            // …and Start cannot re-pin it: the run happens into the default, and
            // a default is not a choice.
            controller.rememberDailiesChoices(from: model)
            #expect(controller.settings.dailies.destinationPath == nil,
                    "starting a run re-pinned the default as an override")

            // Through the blob, which is what a relaunch reads: nothing stored
            // means the folder follows the record folder wherever it moves.
            let reloaded: CaptureSettings = CaptureSettings.loaded(from: controller.defaults)
            #expect(reloaded.dailies.destinationPath == nil)
            let nextShow: URL = root.appendingPathComponent("Day2")
            controller.settings.capture.destinationPath = nextShow.path
            model.prepare(takes: [], settings: controller.settings,
                          defaultFolder: controller.defaultDailiesFolder)
            #expect(model.destination?.path
                == nextShow.appendingPathComponent("Dailies").path,
                    "re-pointing the record folder did not re-aim the dailies")
        }
    }

    /// What the engine is told about a take: the `_DAILY` name, the composed
    /// project · camera+roll line, and the locale-proof date.
    @Test func aTakeBecomesAnItemWithComposedBurninFacts() async throws {
        try await ControllerHarness.run(configure: {
            $0.naming.projectName = "UnitFilm"
            $0.naming.cameraLabel = "A"
        }, { controller, root in
            var take = ControllerFixtures.take(named: "A001C07", in: root)
            take.recordedAt = Date(timeIntervalSince1970: 1_754_092_800) // 2025-08-02 UTC
            let item = DailiesQueueModel.item(for: take,
                                              settings: controller.settings)
            #expect(item.outputName == "A001C07_DAILY")
            #expect(item.clipName == "A001C07")
            // The project ALONE: the camera and the roll used to be appended,
            // and the roll is already in the file name this run writes, so a
            // strip that repeated it spent itself on nothing.
            #expect(item.projectLine == "UnitFilm")
            #expect(item.dateText.count == 10 && item.dateText.hasPrefix("2025-08-0"))
            #expect(item.startTimecode == take.startTimecode)
        })
    }
}
