import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// **The cart's own paperwork reaching a file** (owner: "плюс хотелось бы иметь
/// возможность отгружать отчеты проделанной работы по дейликам и по слитым
/// карточкам").
///
/// `WorkReportTests` in CaptureCore is about what the documents SAY. This is
/// the other half: that each is built out of the right record, offered under a
/// name somebody can find later, and written where the panel was pointed.
@Suite @MainActor struct ControllerWorkReportTests {
    private func entry(_ name: String, seconds: Double,
                       size: Int64) -> DailiesJournal.Entry {
        DailiesJournal.Entry(
            source: "\(name).mov", sourceSize: size * 4,
            sourceModified: Date(timeIntervalSince1970: 1_000_000),
            recipe: "prores422/1920", output: "\(name)_DAILY.mov",
            outputSize: size, outputName: "\(name)_DAILY.mov",
            outputSeconds: seconds, outputAudio: 1,
            finishedAt: Date(timeIntervalSince1970: 1_000_000))
    }

    /// A finished offload that never touched a disk — everything the history
    /// stores is on the report, so the store can be filled without a copy.
    private func report(source: String, verified: Int = 128) -> OffloadReport {
        OffloadReport(
            run: OffloadRunFacts(
                source: URL(fileURLWithPath: source), algorithm: .xxh64,
                creator: .current(version: "0.1.0"),
                span: OffloadSpan(started: Date(), finished: Date()),
                card: OffloadVolume(files: 128, bytes: 64_000_000_000)),
            filesProcessed: 128, wasCancelled: false,
            destinations: [OffloadDestinationResult(
                id: 0, url: URL(fileURLWithPath: "/Volumes/SSD1/CARD"),
                totals: OffloadDestinationTotals(
                    filesVerified: verified, filesTotal: 128,
                    bytesWritten: 32_000_000_000, elapsed: 620),
                failure: nil, wasCancelled: false)])
    }

    // MARK: - the dailies half

    /// It is built from the FOLDER's journal, which is the same decision the
    /// verify pass makes: a folder also holds whatever else somebody put in
    /// it, and a report that walked the directory would count a reference clip
    /// somebody copied in as a daily this cart made.
    @Test func theDailiesReportIsBuiltFromTheFoldersJournal() async throws {
        try await ControllerHarness.run { controller, root in
            let dailies = root.appendingPathComponent("DAILIES")
            try FileManager.default.createDirectory(
                at: dailies, withIntermediateDirectories: true)
            var journal = DailiesJournal()
            journal.entries = [self.entry("A001C001", seconds: 120,
                                          size: 1_000_000_000),
                               self.entry("A001C002", seconds: 60,
                                          size: 500_000_000)]
            _ = try DailiesProgressJournal.write(journal, into: dailies)
            // something ELSE in the folder, which must not be counted
            try Data([1, 2, 3]).write(
                to: dailies.appendingPathComponent("reference.mov"))
            controller.settings.naming.projectName = "Nightshoot"

            let destination = root.appendingPathComponent("work.txt")
            try await FakeFilePanel.installed(saving: [destination]) { panel in
                controller.exportDailiesWorkReport(for: dailies)
                #expect(panel.lastSaveName?.hasPrefix("Nightshoot_dailies_")
                        == true, "\(panel.lastSaveName ?? "nothing")")
                #expect(panel.lastSaveName?.hasSuffix(".txt") == true)
            }
            let text: String = try String(contentsOf: destination,
                                          encoding: .utf8)
            #expect(text.contains("A001C001.mov → A001C001_DAILY.mov"), "\(text)")
            #expect(text.contains("3 min 00 s"), "\(text)")
            #expect(!text.contains("reference.mov"),
                    "the report counted a file nobody rendered")
            #expect(controller.lastError == nil)
            #expect(controller.lastNotice
                == L("work_report_saved", "work.txt"))
        }
    }

    /// A folder nothing has been rendered into is a real report — the DIT
    /// presses it before the first pass finishes — and it must not refuse.
    @Test func aFolderWithNoJournalStillWritesAReport() async throws {
        try await ControllerHarness.run { controller, root in
            let destination = root.appendingPathComponent("empty.txt")
            try await FakeFilePanel.installed(saving: [destination]) { _ in
                controller.exportDailiesWorkReport(for: root)
            }
            let text: String = try String(contentsOf: destination,
                                          encoding: .utf8)
            #expect(text.contains(root.path))
            #expect(controller.lastError == nil)
        }
    }

    // MARK: - the cards half

    @Test func theCardReportIsBuiltFromTheOffloadHistory() async throws {
        try await ControllerHarness.run { controller, root in
            controller.offloadHistory.fileURL =
                root.appendingPathComponent("history.json")
            controller.offloadHistory.record(self.report(
                source: "/Volumes/CARD_A001"))
            controller.offloadHistory.record(self.report(
                source: "/Volumes/CARD_A002", verified: 120))

            let destination = root.appendingPathComponent("cards.txt")
            try await FakeFilePanel.installed(saving: [destination]) { panel in
                controller.exportCardWorkReport()
                #expect(panel.lastSaveName?.hasSuffix(".txt") == true)
            }
            let text: String = try String(contentsOf: destination,
                                          encoding: .utf8)
            #expect(text.contains("/Volumes/CARD_A001"), "\(text)")
            #expect(text.contains("/Volumes/CARD_A002"), "\(text)")
            // 128 files each, and only the first came back fully verified
            #expect(text.contains("128 of 128 files"), "\(text)")
            #expect(text.contains("120 of 128 files"), "\(text)")
            #expect(text.contains("→ /Volumes/SSD1/CARD"), "\(text)")
            #expect(controller.lastError == nil)
        }
    }

    /// Cancelling the panel writes nothing and says nothing — a cancelled
    /// export is a decision, like every other export in the app.
    @Test func cancellingAWorkReportIsSilent() async throws {
        try await ControllerHarness.run { controller, root in
            controller.lastNotice = nil
            try await FakeFilePanel.installed { panel in
                controller.exportCardWorkReport()
                controller.exportDailiesWorkReport(for: root)
                #expect(panel.saveRequests.count == 2)
            }
            #expect(controller.lastNotice == nil)
            #expect(controller.lastError == nil)
        }
    }

    /// A write that fails is reported with the document's own name in front of
    /// it: silence here means a day's paperwork is missing and nobody finds out
    /// until the morning.
    @Test func aWorkReportThatCannotBeWrittenSaysSo() async throws {
        try await ControllerHarness.run { controller, root in
            let dead = root.appendingPathComponent("gone/cards.txt")
            try await FakeFilePanel.installed(saving: [dead]) { _ in
                controller.exportCardWorkReport()
            }
            #expect(controller.lastError?.hasPrefix(
                L("toast_work_report_failed", "").components(
                    separatedBy: ":").first ?? "x") == true,
                "\(controller.lastError ?? "nothing")")
        }
    }
}
