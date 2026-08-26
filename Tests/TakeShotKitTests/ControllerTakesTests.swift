import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// Ratings and comments are the day's paperwork, and the only place they
/// survive the app is the CSV next to the takes — "ratings/comments silently
/// not persisting is a day-loss bug", as the export path itself says. These
/// pin the edit operations and the fact that every one of them reaches the log,
/// retired takes included.
@Suite @MainActor struct ControllerTakesTests {
    private func seed(_ controller: CaptureController, in root: URL,
                      count: Int = 2) throws -> [Take] {
        let takes = (1...count).map {
            ControllerFixtures.take(named: String(format: "A001C%02d", $0),
                                    in: root, clip: $0,
                                    recordedAt: Date(timeIntervalSince1970:
                                                        1_700_000_000 + Double($0)))
        }
        for take in takes { try ControllerFixtures.placeholder(for: take) }
        controller.takes = takes
        return takes
    }

    /// Read the sidecar once it says everything the caller is about to assert,
    /// and hand back the very text that said so.
    ///
    /// The CSV is written on a background queue, so a read has to wait — and
    /// WHAT it waits for is the whole of this. The old shape polled for ONE
    /// needle while its callers went on to assert other facts, and each of
    /// those facts is a SEPARATE write: an edit rewrites the file, so three
    /// edits are three rewrites. Quiet, all three land inside one 50 ms poll
    /// and the test passes; loaded, the file is read between them. Read at the
    /// moment the comment lands, the log says
    /// `A001C02.mov,001,2,,boom in frame` — no rating, no `Bad:` prefix — and
    /// two assertions about a file that was still being written fail. That is
    /// a real red run on this machine, and it is reproduced here by moving the
    /// read one statement earlier.
    ///
    /// It also read the file a SECOND time to return it, so the text asserted
    /// on was never the text the wait had looked at. One read now.
    ///
    /// This is CLAUDE.md's rule about waits in the form it takes for a file:
    /// poll for the OUTCOME — the caller's whole claim — on an I/O-sized
    /// budget, never for one fact that happens to arrive first.
    ///
    /// Rows rather than substrings, and each has to match a COMPLETE line.
    /// `TakeLogExporter` writes `atomically: true`, so no reader can see a
    /// torn file today; a `contains` that half a row could satisfy would make
    /// this helper quietly depend on that, and the row form does not.
    private func log(_ root: URL, rows: [String],
                     file: String = TakeLogExporter.fileName) async -> String {
        let url = root.appendingPathComponent(file)
        var settled: String = ""
        await ControllerWait.untilWritten {
            guard let text: String = try? String(contentsOf: url,
                                                 encoding: .utf8)
            else { return false }
            let lines: [String] = text.split(separator: "\n").map(String.init)
            guard rows.allSatisfy({ (row: String) -> Bool in
                lines.contains { (line: String) -> Bool in line.contains(row) }
            }) else { return false }
            settled = text
            return true
        }
        return settled
    }

    @Test func ratingCyclesNoneGoodBadNone() async throws {
        try await ControllerHarness.run { controller, root in
            let takes = try seed(controller, in: root, count: 1)
            let take = try #require(takes.first)

            controller.cycleRating(take)
            #expect(controller.takes[0].rating == .good)
            controller.cycleRating(controller.takes[0])
            #expect(controller.takes[0].rating == .bad)
            controller.cycleRating(controller.takes[0])
            #expect(controller.takes[0].rating == .none)
        }
    }

    /// The hotkey is a toggle, not a setter: pressing "good" on an
    /// already-good take clears it instead of doing nothing.
    @Test func theRatingHotkeyTogglesTheLastTake() async throws {
        try await ControllerHarness.run { controller, root in
            _ = try seed(controller, in: root, count: 2)

            controller.toggleLastRating(.good)
            #expect(controller.takes[1].rating == .good)
            #expect(controller.takes[0].rating == .none)

            controller.toggleLastRating(.good)
            #expect(controller.takes[1].rating == .none)

            controller.toggleLastRating(.bad)
            #expect(controller.takes[1].rating == .bad)
            // switching straight from bad to good must not need a clear first
            controller.toggleLastRating(.good)
            #expect(controller.takes[1].rating == .good)
        }
    }

    @Test func theHotkeyIsHarmlessWithAnEmptyList() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.toggleLastRating(.good)
            #expect(controller.takes.isEmpty)
        }
    }

    @Test func commentsAreStoredOnTheMatchingTake() async throws {
        try await ControllerHarness.run { controller, root in
            let takes = try seed(controller, in: root, count: 2)

            controller.setComment("soft focus", for: try #require(takes.first))
            #expect(controller.takes[0].comment == "soft focus")
            #expect(controller.takes[1].comment.isEmpty)
        }
    }

    @Test func ratingsAndCommentsReachTheMetadataLog() async throws {
        try await ControllerHarness.run { controller, root in
            let takes = try seed(controller, in: root, count: 2)
            controller.setRating(.good, for: try #require(takes.first))
            controller.setComment("boom in frame", for: controller.takes[1])
            controller.setRating(.bad, for: controller.takes[1])

            // Every fact below is a separate write, so the wait is for all of
            // them — see `log(_:rows:)` for what waiting for one of them cost.
            // Resolve reads the Good Take checkbox from the fourth column.
            let csv: String = await log(root, rows: [
                "A001C01.mov,001,1,true",
                "A001C02.mov,001,2,false,Bad: boom in frame",
            ])

            #expect(csv.contains("A001C01.mov"))
            #expect(csv.contains("A001C01.mov,001,1,true"))
            #expect(csv.contains("A001C02.mov,001,2,false"))
            #expect(csv.contains("Bad: boom in frame"))
        }
    }

    /// The normal end of a shift is the DIT moving the footage into the
    /// archive. Rewriting the CSV from the shrunken panel turned that into the
    /// destruction of the day's metadata; retired takes must stay in the log.
    @Test func retiredTakesStayInTheLog() async throws {
        try await ControllerHarness.run { controller, root in
            let live = ControllerFixtures.take(
                named: "A001C02", in: root, clip: 2,
                recordedAt: Date(timeIntervalSince1970: 1_700_000_002))
            try ControllerFixtures.placeholder(for: live)
            controller.takes = [live]
            controller.retiredTakes = [ControllerFixtures.take(
                named: "A001C01", in: root, clip: 1,
                recordedAt: Date(timeIntervalSince1970: 1_700_000_001))]

            controller.exportTakeLog()
            // Both rows, because the order of the two is the claim.
            let csv: String = await log(root, rows: ["A001C01.mov",
                                                    "A001C02.mov"])

            #expect(csv.contains("A001C02.mov"))
            // and in recording order, not "whatever is still on disk first"
            let moved = try #require(csv.range(of: "A001C01.mov"))
            let kept = try #require(csv.range(of: "A001C02.mov"))
            #expect(moved.lowerBound < kept.lowerBound)
        }
    }

    @Test func markersGetTheirOwnSidecar() async throws {
        try await ControllerHarness.run { controller, root in
            var take = ControllerFixtures.take(named: "A001C01", in: root)
            take.markers = [TakeMarker(seconds: 1.5, timecodeText: "10:00:01:12",
                                       note: "focus")]
            try ControllerFixtures.placeholder(for: take)
            controller.takes = [take]

            controller.exportTakeLog()
            // All three facts, and each has to be on a complete line — the
            // marker's row carries them together, and a wait that named one of
            // them would be the very shape `log(_:rows:)` exists to stop.
            let csv: String = await log(
                root, rows: ["A001C01.mov", "10:00:01:12", "focus"],
                file: TakeLogExporter.markersFileName)
            #expect(csv.contains("A001C01.mov"))
            #expect(csv.contains("10:00:01:12"))
            #expect(csv.contains("focus"))
        }
    }

    /// A delete that fails must say so and leave the take in the panel — the
    /// alternative is a take that disappears from the list while its file is
    /// still on the card.
    @Test func aFailedDeleteKeepsTheTakeAndReportsIt() async throws {
        try await ControllerHarness.run { controller, root in
            let take = ControllerFixtures.take(named: "not-on-disk", in: root)
            controller.takes = [take]

            controller.deleteTake(take)

            #expect(controller.takes.count == 1)
            #expect(controller.lastError != nil)
            #expect(controller.lastError?
                .hasPrefix(localizedHead("toast_delete_failed")) == true)
        }
    }

    @Test func aFailedOtherFileDeleteLeavesTheListAlone() async throws {
        try await ControllerHarness.run { controller, root in
            let url = root.appendingPathComponent("missing.mp4")
            controller.otherFiles = [url]

            controller.deleteOtherFile(url)

            #expect(controller.otherFiles == [url])
            #expect(controller.lastError?
                .hasPrefix(localizedHead("toast_delete_failed")) == true)
        }
    }
}
