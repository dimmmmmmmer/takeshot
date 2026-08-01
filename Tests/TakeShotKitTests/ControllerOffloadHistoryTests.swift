import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// The log of past offloads (owner item 18).
///
/// "Have I already copied this card?" is a question with an expensive wrong
/// answer in both directions — a card wiped twice, or a card carried home for
/// nothing — and until this existed the only record was on the destination
/// disk, which by then is in a case in a van. So what is pinned here is that a
/// run lands in the log whatever happened to it, that the log survives a
/// relaunch, that it cannot grow without limit, and that it is not kept in the
/// record folder, which is emptied and re-pointed between shooting days.
@Suite @MainActor struct ControllerOffloadHistoryTests {
    private func scratch(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("takeshot-history-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url,
                                                withIntermediateDirectories: true)
        return url
    }

    /// A tiny card: two files, one of them in a subfolder.
    private func makeCard(_ root: URL) throws -> URL {
        let source = root.appendingPathComponent("CARD_A001")
        let nested = source.appendingPathComponent("DCIM")
        try FileManager.default.createDirectory(at: nested,
                                                withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: source.appendingPathComponent("A001C001.mov"))
        try Data([4, 5]).write(to: nested.appendingPathComponent("A001C002.mov"))
        return source
    }

    /// A finished run that never touched a disk. Everything the log stores is
    /// on the report, so the store can be exercised without an offload.
    private func report(source: String = "/Volumes/CARD_A001",
                        destinations: [String] = ["/Volumes/SSD1/CARD_A001"],
                        verified: Int = 128, failure: String? = nil,
                        cancelled: Bool = false) -> OffloadReport {
        let results = destinations.enumerated().map { index, path in
            OffloadDestinationResult(
                id: index, url: URL(fileURLWithPath: path),
                totals: OffloadDestinationTotals(
                    filesVerified: verified, filesTotal: 128,
                    bytesWritten: 32_000_000_000, elapsed: 620),
                failure: failure, wasCancelled: cancelled)
        }
        return OffloadReport(
            run: OffloadRunFacts(
                source: URL(fileURLWithPath: source), algorithm: .xxh64,
                creator: .current(version: "0.1.0"),
                span: OffloadSpan(started: Date(), finished: Date()),
                card: OffloadVolume(files: 128, bytes: 64_000_000_000)),
            filesProcessed: 128, wasCancelled: cancelled,
            destinations: results)
    }

    // MARK: - where it lives

    /// NOT in the record folder. That folder changes with the project, gets
    /// emptied or archived between days, and the card being offloaded has
    /// nothing to do with it in the first place.
    @Test func theLogLivesInApplicationSupport() {
        let url = OffloadHistoryStore.defaultURL

        #expect(url.pathComponents.contains("Application Support"))
        #expect(url.pathComponents.contains("TakeShot"))
        #expect(url.lastPathComponent == "offload-history.json")
    }

    // MARK: - a real run

    /// The whole point, end to end: a card is copied, and what happened is
    /// still on this Mac after the app is closed.
    @Test func aFinishedRunIsLoggedAndSurvivesARelaunch() async throws {
        try await ControllerHarness.run { controller, _ in
            let box = try self.scratch("run")
            defer { try? FileManager.default.removeItem(at: box) }
            let source = try self.makeCard(box)
            let disk = box.appendingPathComponent("SSD1")
            let model = controller.offload
            model.source = source
            model.addDestination(disk)

            model.start()
            #expect(await ControllerWait.untilWritten { model.report != nil })

            let logged = try #require(controller.offloadHistory.runs.first)
            #expect(controller.offloadHistory.runs.count == 1)
            #expect(logged.verdict == .verified)
            #expect(logged.sourceName == "CARD_A001")
            #expect(logged.files == 2)
            #expect(logged.filesVerified == 2)
            #expect(logged.destinationPaths
                == [disk.appendingPathComponent("CARD_A001").path])

            // The relaunch: a second store reading the same file is exactly
            // what `completeStartup` does on the next launch.
            let reopened = OffloadHistoryStore()
            reopened.fileURL = controller.offloadHistory.fileURL
            #expect(reopened.runs.count == 1)
            #expect(reopened.runs.first?.id == logged.id)
            #expect(reopened.runs.first?.sourceName == "CARD_A001")
        }
    }

    /// A run that went wrong is the one somebody comes back to the list looking
    /// for. A log of only the good days answers "have I copied this card?" with
    /// a confident no.
    @Test func aFailedRunIsLoggedTooAndNamedAsFailed() async throws {
        try await ControllerHarness.run { controller, _ in
            let box = try self.scratch("bad")
            defer { try? FileManager.default.removeItem(at: box) }
            let source = try self.makeCard(box)
            let disk = box.appendingPathComponent("SSD1")
            // A regular file standing where this destination's card folder has
            // to be created.
            try FileManager.default.createDirectory(
                at: disk, withIntermediateDirectories: true)
            try Data([0]).write(to: disk.appendingPathComponent("CARD_A001"))
            let model = controller.offload
            model.source = source
            model.addDestination(disk)

            model.start()
            #expect(await ControllerWait.untilWritten { model.report != nil })

            #expect(controller.offloadHistory.runs.first?.verdict == .failed)
            #expect(controller.persistentAlert != nil)
        }
    }

    // MARK: - the store itself

    /// Newest first, and the four verdicts the list draws differently.
    @Test func theVerdictIsTheWorstThingThatHappened() async throws {
        try await ControllerHarness.run { controller, _ in
            let store = controller.offloadHistory

            store.record(self.report())
            #expect(store.runs.first?.verdict == .verified)
            store.record(self.report(verified: 126))
            #expect(store.runs.first?.verdict == .problems)
            store.record(self.report(verified: 40, cancelled: true))
            #expect(store.runs.first?.verdict == .cancelled)
            store.record(self.report(verified: 57, failure: "no space left"))
            #expect(store.runs.first?.verdict == .failed)
            // …and the newest is still on top after four of them
            #expect(store.runs.count == 4)
            #expect(store.runs.last?.verdict == .verified)
        }
    }

    /// Capped. A season of cards would otherwise make the sheet's history
    /// section taller than the screen and the file slower to read every launch.
    @Test func theLogIsCappedAtTwentyRuns() async throws {
        try await ControllerHarness.run { controller, _ in
            let store = controller.offloadHistory

            for index in 0..<25 {
                store.record(self.report(source: "/Volumes/CARD_\(index)"))
            }

            #expect(store.runs.count == OffloadHistoryStore.limit)
            #expect(store.runs.first?.sourceName == "CARD_24")
            #expect(store.runs.last?.sourceName == "CARD_5")
            // …and the cap holds across a relaunch rather than only in memory
            let reopened = OffloadHistoryStore()
            reopened.fileURL = store.fileURL
            #expect(reopened.runs.count == OffloadHistoryStore.limit)
            #expect(reopened.runs.first?.sourceName == "CARD_24")
        }
    }

    /// A file from an older build (or a half-written one) means "no history",
    /// not a broken sheet: this is a convenience index, and refusing to open
    /// the offload sheet over it would be the tail wagging the dog.
    @Test func anUnreadableLogIsTreatedAsEmpty() async throws {
        try await ControllerHarness.run { controller, root in
            let store = controller.offloadHistory
            store.record(self.report())
            #expect(store.runs.count == 1)

            let broken = root.appendingPathComponent("broken-history.json")
            try Data("{ not json at all".utf8).write(to: broken)
            store.fileURL = broken

            #expect(store.runs.isEmpty)
        }
    }

    /// The row's own text, which is what the operator actually scans: the card,
    /// where it went, and how much of it was verified.
    @Test func aRowNamesTheCardAndWhereItWent() async throws {
        try await ControllerHarness.run { controller, _ in
            let store = controller.offloadHistory
            store.record(self.report(destinations: ["/Volumes/SSD1/CARD_A001"]))
            let single = try #require(store.runs.first)
            #expect(OffloadHistoryList.headline(single)
                == "CARD_A001 → CARD_A001")

            store.record(self.report(destinations: ["/Volumes/SSD1/CARD_A001",
                                                    "/Volumes/SSD2/CARD_A001",
                                                    "/Volumes/SSD3/CARD_A001"]))
            let several = try #require(store.runs.first)
            // Three names on one line is worth less than the count; one name is
            // worth more than the number 1.
            #expect(OffloadHistoryList.headline(several)
                .hasPrefix("CARD_A001 → "))
            #expect(OffloadHistoryList.headline(several).contains("3"))
            #expect(OffloadHistoryList.verdictKey(several.verdict)
                == "offload_history_ok")
        }
    }
}
