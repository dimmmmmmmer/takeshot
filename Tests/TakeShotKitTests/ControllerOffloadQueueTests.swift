import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// **Several cards in one press.**
///
/// The sheet used to copy one folder, so a shooting day — two camera cards and
/// a sound roll — was three runs, each one a wait at the machine before the
/// next could be started (owner: "вот выбор папок для копирования — давай
/// сделаем как во втором блоке. вариант добавлять несколько папок и удалять из
/// списка").
///
/// The cards are copied ONE AT A TIME, each with its own report and its own
/// manifest, and that is the part worth pinning: a manifest is per card by
/// convention, it is what every downstream tool verifies against, and a card
/// that failed has to be identifiable as that card rather than as part of a
/// batch. A queue that merged three cards into one report would be faster to
/// write and would lose the only artefact the rest of the pipeline reads.
@Suite @MainActor struct ControllerOffloadQueueTests {
    private func scratch(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("takeshot-queue-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url,
                                                withIntermediateDirectories: true)
        return url
    }

    /// One file, named after the card so a copy can be told apart from another
    /// card's copy on the same disk.
    private func makeCard(_ name: String, salt: UInt8 = 0) throws -> URL {
        let source = try scratch(name)
        try Data([1 + salt, 2, 3])
            .write(to: source.appendingPathComponent(Self.clip))
        return source
    }

    /// The one clip on every card. The same name on all of them on purpose:
    /// the cards land in separate folders, so a copy that ended up in the
    /// wrong one would be invisible if the file names differed.
    private static let clip = "A001C001.mov"

    /// Every queued card is copied, each into its own folder, each with its own
    /// report — and the reports come back in the order the cards were queued.
    @Test func theQueueCopiesEveryCardInTurn() async throws {
        try await ControllerHarness.run { controller, _ in
            let first = try self.makeCard("card-a")
            let second = try self.makeCard("card-b", salt: 40)
            let third = try self.makeCard("card-c", salt: 80)
            let dest = try self.scratch("dst")
            defer {
                for url in [first, second, third, dest] {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            let model = controller.offload
            for card in [first, second, third] { model.addSource(card) }
            model.addDestination(dest)
            model.start()
            #expect(await ControllerWait.untilWritten {
                !model.isRunning && model.reports.count == 3
            }, "the queue stopped after \(model.reports.count) of 3 cards")

            // Each card's own copy, under its own name, on the disk.
            for card in [first, second, third] {
                let folder = dest.appendingPathComponent(card.lastPathComponent)
                #expect(FileManager.default.fileExists(
                    atPath: folder.appendingPathComponent(Self.clip).path),
                        "\(card.lastPathComponent) was not copied")
                // …and its own manifest, which is what the rest of the
                // pipeline reads. One merged manifest would name files that
                // are not on the card it sits in.
                let mhl = folder.appendingPathComponent("ascmhl")
                let written = (try? FileManager.default
                    .contentsOfDirectory(atPath: mhl.path)) ?? []
                #expect(written.contains { $0.hasSuffix(".mhl") },
                        "\(card.lastPathComponent) got no manifest of its own")
            }
            #expect(model.reports.filter(\.isFullyVerified).count == 3)
            #expect(model.reports.map(\.run.source.lastPathComponent)
                == [first, second, third].map(\.lastPathComponent),
                    "the cards were copied out of order")
            // The counter is cleared when the queue is: a sheet reopened after
            // a run must not read "card 3 of 3" over an idle Start button.
            #expect(model.cardIndex == 0)
            #expect(model.cardCount == 0)
        }
    }

    /// Every card is logged separately, so the offload history answers "have I
    /// copied this card?" — the question it exists for — for each of them.
    @Test func everyCardGetsItsOwnHistoryEntry() async throws {
        try await ControllerHarness.run { controller, _ in
            let first = try self.makeCard("log-a")
            let second = try self.makeCard("log-b", salt: 40)
            let dest = try self.scratch("log-dst")
            defer {
                for url in [first, second, dest] {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            let model = controller.offload
            model.addSource(first)
            model.addSource(second)
            model.addDestination(dest)
            model.start()
            #expect(await ControllerWait.untilWritten {
                !model.isRunning && model.reports.count == 2
            })
            let logged = controller.offloadHistory.runs
                .map(\.sourcePath)
            for card in [first, second] {
                #expect(logged.contains { $0.hasSuffix(card.lastPathComponent) },
                        "\(card.lastPathComponent) is not in the history")
            }
        }
    }

    /// **Cancel stops the QUEUE, not just the card in flight.**
    ///
    /// The failure this pins is the quiet one: a cancel that only stopped the
    /// current card would go silent, and then start the next one by itself —
    /// the operator having asked for the opposite, and having pulled the disk
    /// on the strength of it.
    @Test func cancelStopsTheWholeQueue() async throws {
        try await ControllerHarness.run { controller, _ in
            let first = try self.makeCard("stop-a")
            let second = try self.makeCard("stop-b", salt: 40)
            let dest = try self.scratch("stop-dst")
            defer {
                for url in [first, second, dest] {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            let model = controller.offload
            model.addSource(first)
            model.addSource(second)
            model.addDestination(dest)
            model.start()
            // Pressed while the survey is still out — the first thing a run
            // does, and the moment the button appears.
            model.cancel()
            #expect(await ControllerWait.untilWritten {
                !model.isRunning && !model.isSurveying
            })
            // Nothing was copied at all: the answer came back to a cancelled
            // queue, so not even the first card was begun.
            #expect(model.reports.isEmpty,
                    "the queue copied a card after cancel")
            for card in [first, second] {
                #expect(!FileManager.default.fileExists(
                    atPath: dest.appendingPathComponent(
                        card.lastPathComponent).path),
                        "\(card.lastPathComponent) was copied after cancel")
            }
            #expect(model.cardIndex == 0)
        }
    }

    /// Two cards with the same NAME land in one folder on the destination and
    /// overwrite each other. `addSource` refuses the same card twice, but two
    /// different paths can still end in "A001" — two rigs, two days, one
    /// careless label — and this is the case that costs footage rather than a
    /// click, so it is refused before the run rather than found in a manifest.
    @Test func twoCardsWithOneNameAreRefused() async throws {
        try await ControllerHarness.run { controller, _ in
            let model = controller.offload
            model.addSource(URL(fileURLWithPath: "/Volumes/RIG1/A001"))
            model.addDestination(URL(fileURLWithPath: "/Volumes/SSD1"))
            #expect(model.validationMessage == nil)
            #expect(model.canStart)

            model.addSource(URL(fileURLWithPath: "/Volumes/RIG2/A001"))
            #expect(model.validationMessage == L("offload_error_same_name"))
            #expect(!model.canStart, "a run that would overwrite a card started")
        }
    }

    /// The same card twice is not a plan, and adding it again is a no-op rather
    /// than a second row that would collide with the first.
    @Test func theSameCardIsNotQueuedTwice() async throws {
        try await ControllerHarness.run { controller, _ in
            let model = controller.offload
            model.addSource(URL(fileURLWithPath: "/Volumes/CARD/A001"))
            model.addSource(URL(fileURLWithPath: "/Volumes/CARD/A001/"))
            #expect(model.sources.count == 1)
        }
    }

    /// A card that is queued but not yet copied still blocks a destination that
    /// sits inside it — the check has to look at every card, not only the first.
    @Test func nestingIsCheckedForEveryQueuedCard() async throws {
        try await ControllerHarness.run { controller, _ in
            let model = controller.offload
            model.addSource(URL(fileURLWithPath: "/Volumes/CARD_A"))
            model.addSource(URL(fileURLWithPath: "/Volumes/SSD1"))
            model.addDestination(URL(fileURLWithPath: "/Volumes/SSD1"))
            // The second card would be copied into a folder inside itself.
            #expect(model.validationMessage == L("offload_error_nested"))
        }
    }
}

/// The resume question, asked in the middle of a queue.
///
/// Its own suite because it needs a card that has already been copied once, and
/// building that is the whole fixture. The path matters more than it looks:
/// the queue is a chain of callbacks, and the question is the one place the
/// chain STOPS and waits for a person. A chain that could not be restarted from
/// there would strand every card behind the one being asked about — with the
/// sheet showing a question and the run showing nothing.
@Suite @MainActor struct ControllerOffloadQueueResumeTests {
    private func scratch(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("takeshot-qresume-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url,
                                                withIntermediateDirectories: true)
        return url
    }

    private func makeCard(_ name: String, salt: UInt8) throws -> URL {
        let source = try scratch(name)
        try Data([1 + salt, 2, 3])
            .write(to: source.appendingPathComponent("A001C001.mov"))
        return source
    }

    @Test func aQuestionOnTheSecondCardDoesNotStrandTheThird() async throws {
        try await ControllerHarness.run { controller, _ in
            let first = try self.makeCard("a", salt: 0)
            let second = try self.makeCard("b", salt: 40)
            let third = try self.makeCard("c", salt: 80)
            let dest = try self.scratch("dst")
            defer {
                for url in [first, second, third, dest] {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            let model = controller.offload
            model.addDestination(dest)

            // Card B alone, first, so the disk already holds a copy of it.
            model.addSource(second)
            model.start()
            #expect(await ControllerWait.untilWritten { !model.isRunning
                && model.reports.count == 1 })

            // Now all three, B in the middle: its copy is already there, so
            // the queue stops on it and asks.
            model.sourceRows = []
            for card in [first, second, third] { model.addSource(card) }
            model.start()
            #expect(await ControllerWait.untilWritten { model.resumeReview != nil },
                    "the queue never asked about the card already on the disk")
            #expect(model.cardIndex == 2, "it asked about card \(model.cardIndex)")
            #expect(model.reports.count == 1, "it walked past the question")

            // Answered — and the queue picks up where it stopped, card C
            // included.
            model.copyEverything()
            #expect(await ControllerWait.untilWritten { !model.isRunning
                && model.reports.count == 3 },
                    "the queue stranded \(3 - model.reports.count) card(s)")
            for card in [first, second, third] {
                #expect(FileManager.default.fileExists(atPath: dest
                    .appendingPathComponent(card.lastPathComponent)
                    .appendingPathComponent("A001C001.mov").path),
                        "\(card.lastPathComponent) never got copied")
            }
        }
    }
}

/// The sheet's editing controls, against the state of the run.
///
/// One rule, asked once, because the last time this was two rules they
/// disagreed: `isOffloadRunning` gated the rows and `canStart` gated the
/// button, and the survey — which fixes the queue before the first byte
/// moves — was inside one and outside the other.
@Suite @MainActor struct ControllerOffloadBusyTests {
    @Test func theRigIsSpokenForWhileTheSurveyIsOut() async throws {
        try await ControllerHarness.run { controller, root in
            let card = root.appendingPathComponent("CARD_A001")
            let dest = root.appendingPathComponent("SSD1")
            for url in [card, dest] {
                try FileManager.default.createDirectory(
                    at: url, withIntermediateDirectories: true)
            }
            try Data([1, 2, 3])
                .write(to: card.appendingPathComponent("A001C001.mov"))
            let model = controller.offload
            model.addSource(card)
            model.addDestination(dest)
            #expect(!controller.isOffloadBusy, "idle and already busy")

            model.isSurveying = true
            #expect(controller.isOffloadBusy,
                    "the card list was editable while the queue was being fixed")
            // …and Start is not offered twice over.
            #expect(!controller.canStartOffload)
            #expect(controller.canStopDiskJob,
                    "there was no way to stop a survey")

            model.isSurveying = false
            #expect(!controller.isOffloadBusy)
            #expect(controller.canStartOffload)
        }
    }
}
