import Foundation
import Testing

@testable import CaptureCore

/// Resuming an offload a lost disk cut short.
///
/// The question this answers is the owner's: "if one of the disks is lost
/// mid-copy, can it later continue from the same place?" Everything here runs a
/// real interrupted offload against scratch directories, reconnects the disk and
/// runs again — and every assertion is a failure that would otherwise be found
/// after the card was wiped: a file skipped that was never copied, a manifest
/// that does not describe the disk it is on, or a disk that finished being
/// written to all over again.
///
/// The gates themselves — a truncated copy, a copy with the right size and the
/// wrong bytes, a manifest from another card — are `OffloadResumeGateTests`.
struct OffloadResumeTests {
    /// What the first two files (the ones that land before the interruption)
    /// occupy — `.metadata` and `CLIPS/index.xml`.
    private static let landedBytes = Int64(32 + 512)

    private func plan(_ source: URL, _ destinations: [URL],
                      resume: Bool = false) -> OffloadPlan {
        OffloadPlan(source: source, destinations: destinations,
                    chunkBytes: OffloadFixtures.chunk, resume: resume)
    }

    // MARK: - the whole point

    /// A destination dies at file three of five; the disk comes back; the second
    /// run copies the three that are missing and nothing else.
    ///
    /// Before this, the second run started at file one — hours of card reading and
    /// disk writing for work already done.
    @Test func aDestinationKilledMidRunIsResumedWithOnlyWhatIsMissing() throws {
        let source = try OffloadFixtures.scratch("res-src")
        let dest = try OffloadFixtures.scratch("res-dst")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: dest)
        }
        try OffloadFixtures.makeCard(at: source)
        try OffloadFixtures.interrupt(dest)

        let first = OffloadEngine.run(plan(source, [dest]))
        let killed = try #require(first.destinations.first)
        #expect(killed.outcome == .failed)
        #expect(killed.totals.filesVerified == OffloadFixtures.filesBeforeDCIM)

        try OffloadFixtures.reconnect(dest)
        let second = OffloadEngine.run(plan(source, [dest], resume: true))

        #expect(second.isFullyVerified)
        let result = try #require(second.destinations.first)
        #expect(result.totals.filesVerified == OffloadFixtures.card.count)
        // The two files already there were neither read off the card nor written
        // again: only the missing three moved.
        let resume = try #require(result.resume)
        #expect(resume.claimed == OffloadFixtures.filesBeforeDCIM)
        #expect(resume.reused == OffloadFixtures.filesBeforeDCIM)
        #expect(resume.reusedBytes == Self.landedBytes)
        #expect(resume.replaced.isEmpty)
        #expect(result.totals.bytesWritten == OffloadFixtures.cardBytes - Self.landedBytes)
        // …and every file on the disk is the card's, whichever run put it there.
        for file in OffloadFixtures.card {
            #expect(try Data(contentsOf: dest.appendingPathComponent(file.path))
                == Data(contentsOf: source.appendingPathComponent(file.path)),
                    "\(file.path)")
        }
        // the operator's own line, in the destination's summary
        let summary = try OffloadFixtures.summaryText(result)
        #expect(summary.contains("Resumed:"))
        #expect(summary.contains("2 files"))
        #expect(summary.contains("already here and re-verified"))
        #expect(summary.contains("VERDICT: all \(OffloadFixtures.card.count) "
            + "files verified"))
    }

    /// The manifest a resumed run writes describes the COMPLETE set on that disk,
    /// not only what moved this time — and the tool that reads it agrees.
    ///
    /// A manifest that omitted files which are present is worse than no manifest
    /// for whoever receives the drive: the generations are how `ascmhl`,
    /// Silverstack and TakeShot's own verify pass decide what to check, so a file
    /// missing from the newest one is a file nobody checks.
    @Test func theResumedManifestDescribesTheWholeDiskAndTheVerifyPassAgrees()
        throws {
        let source = try OffloadFixtures.scratch("resman-src")
        let dest = try OffloadFixtures.scratch("resman-dst")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: dest)
        }
        try OffloadFixtures.makeCard(at: source)
        try OffloadFixtures.interrupt(dest)
        _ = OffloadEngine.run(plan(source, [dest]))
        try OffloadFixtures.reconnect(dest)

        let report = OffloadEngine.run(plan(source, [dest], resume: true))

        let result = try #require(report.destinations.first)
        // Re-verified the way post does it: every <path> resolved against the
        // copy's own root and hashed. The reused entries are in here on the
        // strength of a hash this run computed off this disk, not a claim
        // inherited from the manifest before it.
        #expect(try OffloadFixtures.verifyManifest(
            at: #require(result.manifestURL), root: dest).sorted()
            == OffloadFixtures.card.map(\.path).sorted())
        // …and the shipped verify pass, which reads the NEWEST generation and
        // nothing else, finds the disk whole.
        let checked = try OffloadVerify.run(root: dest,
                                            chunkBytes: OffloadFixtures.chunk)
        #expect(checked.isIntact)
        #expect(checked.filesListed == OffloadFixtures.card.count)
        #expect(checked.missing.isEmpty)
        #expect(checked.mismatched.isEmpty)
        // Nothing left on the disk that no manifest accounts for: the stamp lives
        // under `ascmhl/` and the receipts are named as receipts.
        #expect(checked.extra.isEmpty, "strays: \(checked.extra)")
    }

    // MARK: - per-destination independence

    /// Disk A finished and disk B died. Resuming must not write a byte to A.
    ///
    /// Asserted as identity rather than as contents: a re-copy would produce a
    /// file with the same bytes AND the same modification date (the copy stamps
    /// the card's own dates on), so only the inode says whether the file on the
    /// disk is the one that was there before.
    @Test func aDiskThatFinishedIsNotWrittenToWhileTheOtherResumes() throws {
        let source = try OffloadFixtures.scratch("iso-src")
        let done = try OffloadFixtures.scratch("iso-done")
        let dead = try OffloadFixtures.scratch("iso-dead")
        defer {
            for url in [source, done, dead] {
                try? FileManager.default.removeItem(at: url)
            }
        }
        try OffloadFixtures.makeCard(at: source)
        try OffloadFixtures.interrupt(dead)
        let first = OffloadEngine.run(plan(source, [done, dead]))
        #expect(first.destinations.first { $0.url == done }?.outcome == .verified)
        let before = try OffloadFixtures.inodes(under: done)

        try OffloadFixtures.reconnect(dead)
        let second = OffloadEngine.run(plan(source, [done, dead], resume: true))

        #expect(second.isFullyVerified)
        let finished = try #require(second.destinations.first { $0.url == done })
        #expect(finished.totals.bytesWritten == 0)
        #expect(finished.resume?.reused == OffloadFixtures.card.count)
        #expect(finished.resume?.replaced.isEmpty == true)
        #expect(try OffloadFixtures.inodes(under: done) == before,
                "a file on the finished disk was written again")
        // No second copy alongside either — a resumed destination replaces what
        // it cannot trust and leaves what it can.
        #expect(!FileManager.default.fileExists(atPath: done
            .appendingPathComponent("DCIM/100MEDIA/A001C001_2.mov").path))
        // and the disk that died did the work that was left
        let recovered = try #require(second.destinations.first { $0.url == dead })
        #expect(recovered.resume?.reused == OffloadFixtures.filesBeforeDCIM)
        #expect(recovered.totals.bytesWritten
            == OffloadFixtures.cardBytes - Self.landedBytes)
    }

    /// The cost claim, proven rather than asserted about: a file every
    /// destination already holds is not read off the card AT ALL.
    ///
    /// The card's files are made unreadable before the resumed run. An engine that
    /// opened them would report every one as a source problem — which is what
    /// makes an empty problem list here a measurement and not an opinion.
    @Test(.enabled(if: getuid() != 0, "root reads a mode-000 file anyway"))
    func aFileEveryDestinationHoldsIsNeverReadOffTheCard() throws {
        let source = try OffloadFixtures.scratch("noread-src")
        let dest = try OffloadFixtures.scratch("noread-dst")
        defer {
            // restored before the folder goes, or the tree cannot be removed
            for file in OffloadFixtures.card {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o644],
                    ofItemAtPath: source.appendingPathComponent(file.path).path)
            }
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: dest)
        }
        try OffloadFixtures.makeCard(at: source)
        #expect(OffloadEngine.run(plan(source, [dest])).isFullyVerified)

        for file in OffloadFixtures.card {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0],
                ofItemAtPath: source.appendingPathComponent(file.path).path)
        }
        let report = OffloadEngine.run(plan(source, [dest], resume: true))

        #expect(report.isFullyVerified)
        #expect(report.run.problems.source.isEmpty,
                "the card was read: \(report.run.problems.source)")
        let result = try #require(report.destinations.first)
        #expect(result.totals.bytesWritten == 0)
        #expect(result.resume?.reused == OffloadFixtures.card.count)
        #expect(result.resume?.reusedBytes == OffloadFixtures.cardBytes)
        #expect(result.totals.filesVerified == OffloadFixtures.card.count)
    }

    // MARK: - the awkward cases

    /// Two interrupted runs in a row. Each resumes from the NEWEST generation,
    /// which is itself the manifest of an incomplete run.
    ///
    /// The generation that matters is always the last one written, and each one a
    /// resumed run writes lists everything on the disk at that moment — so the
    /// third run inherits four files from a manifest that inherited two.
    @Test func twoInterruptedRunsInARowResumeFromTheNewestGeneration() throws {
        let source = try OffloadFixtures.scratch("twice-src")
        let dest = try OffloadFixtures.scratch("twice-dst")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: dest)
        }
        try OffloadFixtures.makeCard(at: source)

        // one: dies before DCIM, two files land
        try OffloadFixtures.interrupt(dest)
        _ = OffloadEngine.run(plan(source, [dest]))
        try OffloadFixtures.reconnect(dest)
        // two: dies on the deepest file, so two more land
        try OffloadFixtures.interrupt(dest, at: "DCIM/100MEDIA/sub")
        let second = OffloadEngine.run(plan(source, [dest], resume: true))
        #expect(second.destinations.first?.outcome == .failed)
        #expect(second.destinations.first?.resume?.reused
            == OffloadFixtures.filesBeforeDCIM)
        #expect(second.destinations.first?.totals.filesVerified
            == OffloadFixtures.card.count - 1)
        // three: the disk is back for good
        try OffloadFixtures.reconnect(dest, at: "DCIM/100MEDIA/sub")
        let third = OffloadEngine.run(plan(source, [dest], resume: true))

        #expect(third.isFullyVerified)
        let result = try #require(third.destinations.first)
        #expect(result.resume?.claimed == OffloadFixtures.card.count - 1)
        #expect(result.resume?.reused == OffloadFixtures.card.count - 1)
        // one byte written the third time: the 1-byte file at the bottom of the
        // tree is all that was ever missing.
        #expect(result.totals.bytesWritten == 1)
        #expect(try OffloadFixtures.verifyManifest(
            at: #require(result.manifestURL), root: dest).count
            == OffloadFixtures.card.count)
        // three generations kept, oldest first — ASC MHL never overwrites one
        let manifests = try FileManager.default.contentsOfDirectory(
            at: dest.appendingPathComponent(OffloadMHL.folderName),
            includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == OffloadMHL.fileExtension }
        #expect(manifests.count == 3)
    }

    /// Asked to resume where there is nothing to resume from: an ordinary first
    /// offload. It copies everything and says why in its own summary.
    @Test func aFirstRunAskedToResumeCopiesEverythingAndSaysWhy() throws {
        let source = try OffloadFixtures.scratch("fresh-src")
        let dest = try OffloadFixtures.scratch("fresh-dst")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: dest)
        }
        try OffloadFixtures.makeCard(at: source)

        let report = OffloadEngine.run(plan(source, [dest], resume: true))

        #expect(report.isFullyVerified)
        let result = try #require(report.destinations.first)
        #expect(result.totals.bytesWritten == OffloadFixtures.cardBytes)
        #expect(result.resume?.reused == 0)
        #expect(result.resume?.refusal == "no previous offload in this folder")
        #expect(try OffloadFixtures.summaryText(result)
            .contains("no previous offload in this folder"))
    }

    /// A run that was never asked to resume says nothing about it, which is what
    /// keeps every existing summary and manifest exactly as it was.
    @Test func aRunThatWasNotAskedToResumeCarriesNoResumeFacts() throws {
        let source = try OffloadFixtures.scratch("plain-src")
        let dest = try OffloadFixtures.scratch("plain-dst")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: dest)
        }
        try OffloadFixtures.makeCard(at: source)

        let report = OffloadEngine.run(plan(source, [dest]))

        let result = try #require(report.destinations.first)
        #expect(result.resume == nil)
        let summary = try OffloadFixtures.summaryText(result)
        #expect(!summary.contains("Resumed:"))
    }
}
