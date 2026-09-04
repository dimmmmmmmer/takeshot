import Foundation
import Testing

@testable import CaptureCore

/// **A failed take whose rename could not be made is remembered off the
/// volume.** The rename fails exactly when it matters — the volume that
/// dropped mid-take is the one that will not take the move — and the
/// half-written file keeps its origin tag, so after the remount the scan
/// adopted it as footage and wrote it into the log post reads.
@Suite struct FailedTakeLedgerTests {
    private func scratchLedger() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("failed-takes-\(UUID().uuidString).json")
    }

    @Test func aRecordedPathIsRememberedAcrossAReload() {
        let previous = FailedTakeLedger.fileURL
        FailedTakeLedger.fileURL = scratchLedger()
        defer {
            try? FileManager.default.removeItem(at: FailedTakeLedger.fileURL)
            FailedTakeLedger.fileURL = previous
        }
        let url = URL(fileURLWithPath: "/Volumes/CARD/rec/A001C07.mov")
        #expect(!FailedTakeLedger.contains(url))
        FailedTakeLedger.record(url)
        #expect(FailedTakeLedger.contains(url), "the ledger forgot on the spot")
        // file-backed: a fresh process asks the same file
        let raw = (try? Data(contentsOf: FailedTakeLedger.fileURL))
            .flatMap { String(data: $0, encoding: .utf8) }
        #expect(raw?.contains("A001C07.mov") == true, "nothing reached the disk")
        FailedTakeLedger.forget(url)
        #expect(!FailedTakeLedger.contains(url))
    }

    /// `markFailed` writes the ledger when the move fails, and clears it when
    /// a later move succeeds — so the name and the ledger never both claim it.
    @Test func aRenameThatFailsIsRecordedAndOneThatSucceedsIsForgotten() throws {
        let previous = FailedTakeLedger.fileURL
        FailedTakeLedger.fileURL = scratchLedger()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("markfailed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: FailedTakeLedger.fileURL)
            FailedTakeLedger.fileURL = previous
        }
        let take = root.appendingPathComponent("A001C07.mov")
        try Data([0x00]).write(to: take)
        // a folder that refuses the rename, the way a dropped volume does
        try FileManager.default.setAttributes([.posixPermissions: 0o555],
                                              ofItemAtPath: root.path)
        let unmoved = CapturePipeline.markFailed(take)
        #expect(unmoved == take, "the move succeeded in a read-only folder?")
        #expect(FailedTakeLedger.contains(take), """
            a failed take that kept its healthy name was not written down — \
            the next scan will adopt it as footage
            """)

        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: root.path)
        let moved = CapturePipeline.markFailed(take)
        #expect(moved != take)
        #expect(moved.lastPathComponent.contains(CapturePipeline.failedTakeSuffix))
        #expect(!FailedTakeLedger.contains(take), "the name says it now; the ledger still did too")
    }
}
