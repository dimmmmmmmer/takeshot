import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// Every "show it in the Finder" goes through one helper, and this is what
/// holds it there (owner item 23).
///
/// Never the real Finder: `NSWorkspace` opens a window on the machine running
/// the suite, and a test that could only assert "it did not crash" would say
/// nothing about the half worth asserting — WHICH folder each button reaches
/// for. `FinderOpen.handler` is replaced with a recorder and put back
/// afterwards; the suite is serial, so the substitution cannot leak sideways.
@Suite @MainActor struct ControllerFinderTests {
    /// The handler, and the URLs it was handed.
    private final class Recorder {
        var opened: [URL] = []
    }

    /// Install the recorder for `body` and restore whatever was there before —
    /// leaving a recorder installed would silently disarm the Finder for every
    /// later suite.
    private func recording(_ body: (Recorder) async throws -> Void) async throws {
        let recorder = Recorder()
        let previous = FinderOpen.handler
        FinderOpen.handler = { recorder.opened.append($0) }
        defer { FinderOpen.handler = previous }
        try await body(recorder)
    }

    private func scratch(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("takeshot-finder-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url,
                                                withIntermediateDirectories: true)
        return ControllerFixtures.resolved(url)
    }

    /// The idiom the rest of this follows: the record folder is the app's own,
    /// so it is created if it is missing and then opened.
    @Test func theRecordFolderGoesThroughTheHelper() async throws {
        try await recording { recorder in
            try await ControllerHarness.run { controller, root in
                controller.openDestinationInFinder()
                #expect(recorder.opened == [root])
            }
        }
    }

    /// A folder that is not there is not handed to the Finder at all. An
    /// offload destination whose SSD has been unplugged is the normal state of
    /// an old history row, and a window opening on nothing reads as the app
    /// being broken rather than the disk being absent.
    @Test func aVanishedFolderOpensNothing() async throws {
        try await recording { recorder in
            FinderOpen.folder(URL(fileURLWithPath: "/Volumes/GONE_SSD/CARD_A001"))
            #expect(recorder.opened.isEmpty)
        }
    }

    /// The source tile opens the card itself; a destination tile opens the
    /// copy's own folder once there is one, and the disk the operator chose
    /// before that — a button that does nothing until the copy is under way is
    /// one they stop trying.
    @Test func theSheetOpensTheCardAndEachDestination() async throws {
        let card = try scratch("card")
        let disk = try scratch("disk")
        defer {
            try? FileManager.default.removeItem(at: card)
            try? FileManager.default.removeItem(at: disk)
        }
        try await recording { recorder in
            try await ControllerHarness.run { controller, _ in
                let model = controller.offload
                model.source = card
                model.addDestination(disk)
                let row = try #require(model.rows.first)

                // nothing copied yet: the copy folder does not exist
                let planned = try #require(model.destinationFolder(for: row))
                #expect(model.finderTarget(for: row) == disk)
                try FileManager.default.createDirectory(
                    at: planned, withIntermediateDirectories: true)
                // …by path, not by URL: `appendingPathComponent` consults the
                // filesystem and starts appending a trailing slash the moment
                // the folder exists, so two URLs for the same directory stop
                // comparing equal halfway through this test.
                #expect(model.finderTarget(for: row).path == planned.path)

                FinderOpen.folder(try #require(model.source))
                FinderOpen.folder(model.finderTarget(for: row))
                #expect(recorder.opened.map(\.path)
                    == [card.path, planned.path])
            }
        }
    }

    /// A history row reveals the first destination still on the machine, and
    /// nothing at all when none of them is.
    @Test func aHistoryRowOpensTheDestinationThatIsStillThere() async throws {
        let disk = try scratch("history-disk")
        defer { try? FileManager.default.removeItem(at: disk) }
        try await recording { recorder in
            let gone = URL(fileURLWithPath: "/Volumes/GONE_SSD/CARD_A001")
            let report = OffloadReport(
                run: OffloadRunFacts(
                    source: URL(fileURLWithPath: "/Volumes/CARD_A001"),
                    algorithm: .xxh64, creator: .current(),
                    span: OffloadSpan(started: Date(), finished: Date()),
                    card: OffloadVolume(files: 1, bytes: 1)),
                filesProcessed: 1, wasCancelled: false,
                destinations: [gone, disk].enumerated().map { index, url in
                    OffloadDestinationResult(
                        id: index, url: url,
                        totals: OffloadDestinationTotals(
                            filesVerified: 1, filesTotal: 1, bytesWritten: 1,
                            elapsed: 1))
                })

            OffloadHistoryList.reveal(OffloadRunRecord(report: report))

            #expect(recorder.opened == [disk],
                    "it opened \(recorder.opened) instead of the mounted disk")
        }
    }
}
