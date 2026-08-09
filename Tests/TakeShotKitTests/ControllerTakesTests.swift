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

    /// The CSV is written on a background queue, so every read waits for the
    /// content it is about to assert on rather than for the file to exist.
    private func log(_ root: URL, containing needle: String,
                     file: String = TakeLogExporter.fileName) async -> String {
        let url = root.appendingPathComponent(file)
        func text() -> String? { try? String(contentsOf: url, encoding: .utf8) }
        await ControllerWait.until { text()?.contains(needle) == true }
        return text() ?? ""
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

            let csv = await log(root, containing: "boom in frame")

            #expect(csv.contains("A001C01.mov"))
            // Resolve reads the Good Take checkbox from this column
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
            let csv = await log(root, containing: "A001C01.mov")

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
            let csv = await log(root, containing: "10:00:01:12",
                                file: TakeLogExporter.markersFileName)
            #expect(csv.contains("A001C01.mov"))
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
