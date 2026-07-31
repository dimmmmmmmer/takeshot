import Foundation
import Testing

@testable import CaptureCore

/// What the offload does when something goes wrong — which is the half of the
/// feature that matters, because a copy that worked needs no report. A corrupted
/// copy, a destination that dies mid-run, one that cannot be created at all, and
/// the operator stopping the run: each has to end with the truth in the
/// destination's own summary and nothing overstated in anyone else's.
struct OffloadFailureTests {
    // MARK: - a copy that lands corrupted

    /// The reason the verify pass re-reads the disk at all. The copy is
    /// corrupted after it is written and before it is read back: the run has to
    /// report the file, keep it out of the manifest, and refuse to call the
    /// destination verified.
    @Test func aCorruptedCopyIsReportedAndKeptOutOfTheManifest() throws {
        let source = try OffloadFixtures.scratch("bad-src")
        let dest = try OffloadFixtures.scratch("bad-dst")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: dest)
        }
        try OffloadFixtures.makeCard(at: source)
        let victim = "DCIM/100MEDIA/A001C002.mov"

        let report = OffloadEngine.run(OffloadPlan(
            source: source, destinations: [dest], chunkBytes: OffloadFixtures.chunk,
            didWriteCopy: { copy in
                guard copy.path.hasSuffix("A001C002.mov") else { return }
                OffloadFixtures.flipFirstByte(of: copy)
            }))

        #expect(!report.isFullyVerified)
        let result = try #require(report.destinations.first)
        #expect(result.outcome == .mismatched)
        #expect(result.mismatches == ["\(victim) (checksum mismatch)"])
        #expect(result.totals.filesVerified == OffloadFixtures.card.count - 1)
        // Renamed like a failed take, so nobody mistakes it for footage, and
        // absent from the manifest, so `mhl verify` cannot pass it either.
        #expect(!FileManager.default.fileExists(
            atPath: dest.appendingPathComponent(victim).path))
        #expect(FileManager.default.fileExists(atPath: dest
            .appendingPathComponent("DCIM/100MEDIA/A001C002_MISMATCH.mov").path))
        let xml = try String(contentsOf: #require(result.manifestURL),
                            encoding: .utf8)
        #expect(!xml.contains("A001C002.mov"))
        let summary = try OffloadFixtures.summaryText(result)
        #expect(summary.contains("CHECKSUM MISMATCHES (1)"))
        #expect(summary.contains(victim))
        #expect(summary.contains("do NOT wipe the card"))
    }

    // MARK: - one destination dying

    /// Three SSDs and one bad one is a normal afternoon. The bad one has to fail
    /// with its reason on record while the others finish — the old flow reported
    /// one flat failure count for the whole run.
    @Test func aDestinationThatFailsMidRunDoesNotStopTheOthers() throws {
        let source = try OffloadFixtures.scratch("iso-src")
        let good = try OffloadFixtures.scratch("iso-good")
        let broken = try OffloadFixtures.scratch("iso-broken")
        defer {
            for url in [source, good, broken] {
                try? FileManager.default.removeItem(at: url)
            }
        }
        try OffloadFixtures.makeCard(at: source)
        // A regular file where the card's CLIPS folder has to be created: the
        // first file into CLIPS cannot land, and only on this destination.
        try OffloadFixtures.content(1).write(to: broken.appendingPathComponent("CLIPS"))

        let report = OffloadEngine.run(OffloadPlan(
            source: source, destinations: [good, broken],
            chunkBytes: OffloadFixtures.chunk))

        #expect(!report.isFullyVerified)
        let goodResult = try #require(report.destinations.first { $0.url == good })
        #expect(goodResult.outcome == .verified)
        #expect(goodResult.totals.filesVerified == OffloadFixtures.card.count)
        let brokenResult = try #require(report.destinations.first { $0.url == broken })
        #expect(brokenResult.outcome == .failed)
        #expect(brokenResult.failure?.contains("CLIPS/index.xml") == true)
        #expect(report.failedDestinations.map(\.url) == [broken])
        // Its own summary says why, next to the copies that did land.
        let summary = try OffloadFixtures.summaryText(brokenResult)
        #expect(summary.contains("DESTINATION FAILED"))
        #expect(summary.contains("VERDICT: FAILED"))
        // and the good disk's verdict is not coloured by the other one's failure
        #expect(try OffloadFixtures.summaryText(goodResult)
            .contains("VERDICT: all \(OffloadFixtures.card.count) files verified"))
    }

    @Test func aDestinationThatCannotBeCreatedFailsBeforeAnythingIsCopied() throws {
        let source = try OffloadFixtures.scratch("pre-src")
        let parent = try OffloadFixtures.scratch("pre-dst")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: parent)
        }
        try OffloadFixtures.makeCard(at: source)
        // The destination path is a file, so the folder cannot be made at all.
        let blocked = parent.appendingPathComponent("SSD")
        try OffloadFixtures.content(1).write(to: blocked)

        let report = OffloadEngine.run(OffloadPlan(
            source: source, destinations: [blocked], chunkBytes: OffloadFixtures.chunk))

        let result = try #require(report.destinations.first)
        #expect(result.outcome == .failed)
        #expect(result.totals.filesVerified == 0)
        #expect(result.totals.bytesWritten == 0)
        #expect(result.failure?.isEmpty == false)
    }

    // MARK: - cancel

    /// Cancel is safe: it lands between files, so what is on the disk is whole
    /// and verified, and the summary says where it stopped.
    @Test func cancelStopsBetweenFilesAndSaysSoInTheSummary() throws {
        let source = try OffloadFixtures.scratch("cancel-src")
        let dest = try OffloadFixtures.scratch("cancel-dst")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: dest)
        }
        try OffloadFixtures.makeCard(at: source)
        let token = OffloadCancellation()

        let report = OffloadEngine.run(
            OffloadPlan(source: source, destinations: [dest],
                        chunkBytes: OffloadFixtures.chunk),
            cancellation: token) { progress in
                // Stop after the first file has been through the verify pass.
                if (progress.destinations.first?.filesDone ?? 0) >= 1 {
                    token.cancel()
                }
            }

        #expect(report.wasCancelled)
        #expect(report.filesProcessed == 1)
        let result = try #require(report.destinations.first)
        #expect(result.outcome == .cancelled)
        #expect(result.totals.filesVerified == 1)
        let summary = try OffloadFixtures.summaryText(result)
        #expect(summary.contains("VERDICT: CANCELLED — 1 of "
            + "\(OffloadFixtures.card.count) files verified"))
        // Whatever landed is a whole file, byte for byte — a torn file on an SSD
        // is the one outcome worse than a missing one.
        let manifest = try XMLDocument(contentsOf: #require(result.manifestURL))
        let paths = try manifest.nodes(forXPath: "//*[local-name()='path']")
        #expect(paths.count == 1)
        let copied = try #require(paths.first?.stringValue)
        #expect(try Data(contentsOf: dest.appendingPathComponent(copied))
            == (try Data(contentsOf: source.appendingPathComponent(copied))))
    }

    /// Stop pressed while the LAST file is being copied is not a cancelled
    /// offload: every file on the card is there and verified. A verdict that
    /// said "CANCELLED — do NOT wipe the card" over a complete copy is a false
    /// alarm, and false alarms are how the real ones stop being read.
    @Test func cancelAfterTheLastFileIsNotReportedAsACancel() throws {
        let source = try OffloadFixtures.scratch("late-src")
        let dest = try OffloadFixtures.scratch("late-dst")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: dest)
        }
        try OffloadFixtures.makeCard(at: source)
        let token = OffloadCancellation()

        let report = OffloadEngine.run(
            OffloadPlan(source: source, destinations: [dest],
                        chunkBytes: OffloadFixtures.chunk),
            cancellation: token) { progress in
                // Only once every file has been through the verify pass.
                if (progress.destinations.first?.filesDone ?? 0)
                    >= OffloadFixtures.card.count {
                    token.cancel()
                }
            }

        #expect(!report.wasCancelled)
        #expect(report.isFullyVerified)
        let result = try #require(report.destinations.first)
        #expect(result.outcome == .verified)
        #expect(try OffloadFixtures.summaryText(result)
            .contains("VERDICT: all \(OffloadFixtures.card.count) files verified"))
    }

    // MARK: - a card that will not give up its files

    /// A file the card refuses is the run-level fact that makes it unsafe to
    /// wipe, so it has to reach every destination's summary — the copies
    /// themselves are all fine, which is exactly why nothing else would say so.
    @Test(.enabled(if: getuid() != 0,
                   "root reads a mode-000 file anyway"))
    func anUnreadableCardFileIsReportedInEveryDestinationSummary() throws {
        let source = try OffloadFixtures.scratch("unread-src")
        let first = try OffloadFixtures.scratch("unread-a")
        let second = try OffloadFixtures.scratch("unread-b")
        defer {
            for url in [source, first, second] {
                try? FileManager.default.removeItem(at: url)
            }
        }
        try OffloadFixtures.makeCard(at: source)
        let victim = "DCIM/100MEDIA/A001C001.mov"
        try FileManager.default.setAttributes(
            [.posixPermissions: 0],
            ofItemAtPath: source.appendingPathComponent(victim).path)

        let report = OffloadEngine.run(OffloadPlan(
            source: source, destinations: [first, second],
            chunkBytes: OffloadFixtures.chunk))

        #expect(!report.isFullyVerified)
        #expect(report.run.problems.source.count == 1)
        #expect(report.run.problems.source.first?.hasPrefix(victim) == true)
        for result in report.destinations {
            // Nothing is wrong with the disk itself: every file it did get is
            // verified, and no half-copy of the unreadable one was left behind.
            #expect(result.failure == nil)
            #expect(result.mismatches.isEmpty)
            #expect(result.totals.filesVerified == OffloadFixtures.card.count - 1)
            #expect(!FileManager.default.fileExists(
                atPath: result.url.appendingPathComponent(victim).path))
            let summary = try OffloadFixtures.summaryText(result)
            #expect(summary.contains("SOURCE PROBLEMS (1)"))
            #expect(summary.contains(victim))
            #expect(summary.contains("VERDICT: INCOMPLETE"))
            #expect(summary.contains("do NOT wipe the card"))
        }
    }

    /// An empty card is not an error, and the report still lands: a run that
    /// copied nothing has to be as legible as one that copied a terabyte.
    @Test func anEmptyCardStillProducesBothReports() throws {
        let source = try OffloadFixtures.scratch("empty-src")
        let dest = try OffloadFixtures.scratch("empty-dst")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: dest)
        }

        let report = OffloadEngine.run(OffloadPlan(source: source,
                                                   destinations: [dest],
                                                   chunkBytes: OffloadFixtures.chunk))

        let result = try #require(report.destinations.first)
        #expect(result.outcome == .verified)
        #expect(result.manifestURL != nil)
        #expect(try OffloadFixtures.summaryText(result)
            .contains("VERDICT: all 0 files verified"))
    }
}
