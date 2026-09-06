import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// **The offload records survive one bad element, and a file that could not
/// be read is never written over.** Both lists were decoded whole, so one
/// record from a build that changed a field emptied the list — and the next
/// save wrote that emptiness over the only copy, every "Never" with it.
@MainActor
struct OffloadRecordsLenientTests {
    private func scratchFile(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("takeshot-\(name)-\(UUID().uuidString).json")
    }

    @Test func aLedgerKeepsTheRecordsBesideABrokenOne() throws {
        let url = scratchFile("cards")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("""
            [{"key":"card-1","name":"A001","fingerprint":null,"suppressed":true,"date":0},
             {"broken":true}]
            """.utf8).write(to: url)
        let ledger = OffloadedCardLedger()
        ledger.fileURL = url
        ledger.load()
        #expect(ledger.cards.map(\.key) == ["card-1"],
                "one broken element cost the whole ledger: \(ledger.cards)")
        #expect(!ledger.saveBlocked)
    }

    @Test func aLedgerThatIsNotAListIsNeverWrittenOver() throws {
        let url = scratchFile("cards-bad")
        defer { try? FileManager.default.removeItem(at: url) }
        let bytes = Data("not a list at all".utf8)
        try bytes.write(to: url)
        let ledger = OffloadedCardLedger()
        ledger.fileURL = url
        ledger.load()
        #expect(ledger.cards.isEmpty)
        #expect(ledger.saveBlocked, "an unreadable ledger was not latched")
        ledger.suppress(Self.candidate)
        #expect(try Data(contentsOf: url) == bytes,
                "the only copy was replaced by this launch's list")
    }

    @Test func theHistoryKeepsTheRunsBesideABrokenOneAndNeverWritesOverGarbage() throws {
        let url = scratchFile("history")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("""
            [{"id":"\(UUID().uuidString)","date":0,"sourcePath":"/Volumes/A001",
              "destinationPaths":["/Volumes/SSD"],"verdict":"verified",
              "files":3,"filesVerified":3,"bytes":12},
             {"broken":true}]
            """.utf8).write(to: url)
        let history = OffloadHistoryStore()
        history.fileURL = url
        history.load()
        #expect(history.runs.count == 1, "one broken run cost the history: \(history.runs)")

        let bytes = Data("{ not even a list".utf8)
        try bytes.write(to: url)
        history.load()
        #expect(history.runs.isEmpty)
        #expect(history.saveBlocked)
        history.record(Self.report)
        #expect(try Data(contentsOf: url) == bytes,
                "a run recorded over a file this launch could not read")
    }

    private static var candidate: CardCandidate {
        CardCandidate(volume: MountedVolume(url: URL(fileURLWithPath: "/Volumes/A001"),
                                            name: "A001", uuid: "card-1",
                                            isRemovable: true, isEjectable: true),
                      files: 3, bytes: 12, evidence: .cameraStructure("DCIM"))
    }

    private static var report: OffloadReport {
        OffloadReport(
            run: OffloadRunFacts(source: URL(fileURLWithPath: "/Volumes/A001"),
                                 algorithm: .xxh64, creator: .current(version: "0.2.0"),
                                 span: OffloadSpan(started: Date(), finished: Date()),
                                 card: OffloadVolume(files: 1, bytes: 1)),
            filesProcessed: 1, wasCancelled: false, destinations: [])
    }
}
