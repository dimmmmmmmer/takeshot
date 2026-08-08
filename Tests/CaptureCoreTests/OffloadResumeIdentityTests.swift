import Foundation
import Testing

@testable import CaptureCore

/// Whose manifest a resume is allowed to believe.
///
/// The identity check is the one gate that is not per file, and the only one that
/// can go catastrophically wrong: if a destination's manifest is taken to be this
/// card's when it is another card's, every file gets claimed, re-hashed against
/// the WRONG digests, matched — because the disk really does hold the files those
/// digests describe — and skipped. The disk would end up holding one card's
/// footage under a manifest saying it holds another's, and no later verify would
/// ever disagree, because the manifest and the files on the disk agree with each
/// other perfectly.
///
/// So every test here is a destination that must NOT be believed, and one that
/// must: the survey the operator is shown.
///
/// The per-file gates are `OffloadResumeGateTests`.
struct OffloadResumeIdentityTests {
    // MARK: - never another card's manifest

    /// A different card whose file count and total size are IDENTICAL — the case
    /// the ledger's own fingerprint cannot tell apart.
    ///
    /// Same relative paths, same size for every one of them, different bytes. If
    /// the identity check were the fingerprint alone, every file would be claimed,
    /// re-hashed against the OTHER card's digests, matched, and skipped: the disk
    /// would end up holding card A's footage under a manifest saying it holds card
    /// B's, and no later verify would ever disagree. It is refused instead, on the
    /// source identity the stamp beside the manifest records.
    @Test func aManifestFromAnotherCardWithTheSameFingerprintIsRefused() throws {
        let first = try OffloadFixtures.scratch("twin-a")
        let second = try OffloadFixtures.scratch("twin-b")
        let dest = try OffloadFixtures.scratch("twin-dst")
        defer {
            for url in [first, second, dest] {
                try? FileManager.default.removeItem(at: url)
            }
        }
        try OffloadFixtures.cardAlreadyOffloaded(from: first, to: dest)
        // card B: the same tree, file for file and byte for byte in LENGTH, and
        // different content throughout (a different salt).
        for (index, file) in OffloadFixtures.card.enumerated() {
            let url = second.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try OffloadFixtures.content(file.bytes, salt: index + 500)
                .write(to: url)
        }
        let sameShape = OffloadEngine.scan(second)
        #expect(sameShape.files.map(\.size)
            == OffloadEngine.scan(first).files.map(\.size),
                "the two cards have to look identical for this to prove anything")

        let report = OffloadEngine.run(OffloadFixtures.plan(second, dest, resume: true))

        let result = try #require(report.destinations.first)
        let resume = try #require(result.resume)
        #expect(resume.reused == 0)
        #expect(resume.claimed == 0)
        #expect(resume.refusal == "the copy here was made from a different card")
        // Every byte of card B was copied, and card A's copies are still card A's
        // — nothing was overwritten and nothing was skipped.
        #expect(result.totals.bytesWritten == OffloadFixtures.cardBytes)
        let shared = "DCIM/100MEDIA/A001C001.mov"
        #expect(try Data(contentsOf: dest.appendingPathComponent(shared))
            == Data(contentsOf: first.appendingPathComponent(shared)))
        #expect(try Data(contentsOf: dest
            .appendingPathComponent("DCIM/100MEDIA/A001C001_2.mov"))
            == Data(contentsOf: second.appendingPathComponent(shared)))
        // …and the destination's own summary says why it copied everything
        #expect(try OffloadFixtures.summaryText(result)
            .contains("made from a different card"))
    }

    /// A folder offloaded by another tool, or by a build from before resume
    /// existed: a manifest with no stamp beside it. A manifest whose card cannot
    /// be established is a manifest from an unknown card, so nothing is reused.
    @Test func aManifestWithNoStampBesideItIsRefused() throws {
        let source = try OffloadFixtures.scratch("unstamped-src")
        let dest = try OffloadFixtures.scratch("unstamped-dst")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: dest)
        }
        try OffloadFixtures.cardAlreadyOffloaded(from: source, to: dest)
        try FileManager.default.removeItem(at: dest
            .appendingPathComponent(OffloadMHL.folderName)
            .appendingPathComponent(OffloadResume.stampName))

        let report = OffloadEngine.run(OffloadFixtures.plan(source, dest, resume: true))

        let result = try #require(report.destinations.first)
        #expect(result.resume?.reused == 0)
        #expect(result.resume?.refusal
            == "the manifest here does not say which card it was made from")
        #expect(result.totals.bytesWritten == OffloadFixtures.cardBytes)
    }

    /// A stamp that names an OLDER generation than the newest manifest on the
    /// disk — a second run whose manifest landed and whose stamp did not. The
    /// pairing is checked by name, so the claim is refused rather than read
    /// against the wrong generation.
    @Test func aStampThatNamesTheWrongGenerationIsRefused() throws {
        let source = try OffloadFixtures.scratch("stale-src")
        let dest = try OffloadFixtures.scratch("stale-dst")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: dest)
        }
        try OffloadFixtures.cardAlreadyOffloaded(from: source, to: dest)
        let stampURL = dest.appendingPathComponent(OffloadMHL.folderName)
            .appendingPathComponent(OffloadResume.stampName)
        var stamp = try #require(OffloadResume.readStamp(in: dest))
        stamp.manifest = "0009_never-written.mhl"
        try JSONEncoder().encode(stamp).write(to: stampURL)

        let report = OffloadEngine.run(OffloadFixtures.plan(source, dest, resume: true))

        #expect(report.destinations.first?.resume?.reused == 0)
        #expect(report.destinations.first?.resume?.refusal
            == "the manifest here does not say which card it was made from")
    }

    /// A card that has been shot on since it was copied. The fingerprint is what
    /// notices, exactly as it does for the ledger's "ask about this card again".
    @Test func aCardWithMoreOnItThanWhenItWasCopiedIsRefused() throws {
        let source = try OffloadFixtures.scratch("grown-src")
        let dest = try OffloadFixtures.scratch("grown-dst")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: dest)
        }
        try OffloadFixtures.cardAlreadyOffloaded(from: source, to: dest)
        try OffloadFixtures.content(64)
            .write(to: source.appendingPathComponent("DCIM/100MEDIA/A001C004.mov"))

        let report = OffloadEngine.run(OffloadFixtures.plan(source, dest, resume: true))

        #expect(report.destinations.first?.resume?.reused == 0)
        #expect(report.destinations.first?.resume?.refusal
            == "the card has changed since it was copied here")
    }

    // MARK: - a disk holding more than the plan

    /// A destination whose manifest lists MORE than the card has — footage from
    /// an earlier card that was offloaded into the same folder and is still
    /// listed there.
    ///
    /// What it must not do is claim it: the entry is dropped, the file is left
    /// alone, and the manifest this run writes describes this card. Nothing is
    /// lost by leaving it out — ASC MHL keeps every generation, and the one that
    /// listed it is still on the disk — so the file is reported as a stray by the
    /// newest generation and accounted for by the older one.
    @Test func aManifestListingFilesTheCardDoesNotHaveClaimsOnlyTheCards() throws {
        let source = try OffloadFixtures.scratch("more-src")
        let dest = try OffloadFixtures.scratch("more-dst")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: dest)
        }
        try OffloadFixtures.makeCard(at: source)
        // A destination built by hand, so the manifest can list something the
        // card does not have while still being attested to this card.
        let stray = "EXTRA/from-another-card.mov"
        let strayURL = dest.appendingPathComponent(stray)
        try FileManager.default.createDirectory(
            at: strayURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try OffloadFixtures.content(128, salt: 77).write(to: strayURL)
        var entries: [OffloadEntry] = []
        for file in OffloadFixtures.card {
            let url = source.appendingPathComponent(file.path)
            let copy = dest.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(
                at: copy.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try Data(contentsOf: url).write(to: copy)
            entries.append(OffloadEntry(relativePath: file.path,
                                        size: Int64(file.bytes),
                                        hash: try OffloadFixtures.hash(of: url)))
        }
        entries.append(OffloadEntry(relativePath: stray, size: 128,
                                    hash: try OffloadFixtures.hash(of: strayURL)))
        let scan = OffloadEngine.scan(source)
        let manifest = try OffloadMHL.write(
            entries: entries, into: dest, algorithm: .xxh64,
            creator: .current(), date: Date())
        try OffloadResume.stamp(
            OffloadCardIdentity.of(
                source: source,
                card: OffloadVolume(files: scan.files.count,
                                    bytes: scan.files.reduce(0) { $0 + $1.size })),
            manifest: manifest, into: dest)

        let report = OffloadEngine.run(OffloadFixtures.plan(source, dest, resume: true))

        let result = try #require(report.destinations.first)
        #expect(result.resume?.claimed == OffloadFixtures.card.count)
        #expect(result.resume?.reused == OffloadFixtures.card.count)
        #expect(result.totals.bytesWritten == 0)
        // the older card's file is still there, untouched, and out of the new
        // manifest — which is what makes the verify pass call it a stray
        #expect(FileManager.default.fileExists(atPath: strayURL.path))
        #expect(try OffloadFixtures.verifyManifest(
            at: #require(result.manifestURL), root: dest).sorted()
            == OffloadFixtures.card.map(\.path).sorted())
        let checked = try OffloadVerify.run(root: dest,
                                            chunkBytes: OffloadFixtures.chunk)
        #expect(checked.isIntact)
        #expect(checked.extra == [stray])
    }

    // MARK: - what the operator is asked

    /// The survey the sheet shows: a claim, made without reading a single byte of
    /// footage, and counted against the card the operator is looking at.
    @Test func theSurveyCountsWhatIsThereWithoutReadingIt() throws {
        let source = try OffloadFixtures.scratch("survey-src")
        let dest = try OffloadFixtures.scratch("survey-dst")
        let fresh = try OffloadFixtures.scratch("survey-fresh")
        defer {
            for url in [source, dest, fresh] {
                try? FileManager.default.removeItem(at: url)
            }
        }
        try OffloadFixtures.makeCard(at: source)
        try OffloadFixtures.interrupt(dest)
        _ = OffloadEngine.run(OffloadFixtures.plan(source, dest))
        try OffloadFixtures.reconnect(dest)

        let review = OffloadResume.review(source: source,
                                          destinations: [dest, fresh],
                                          algorithm: .xxh64)

        #expect(review.card.files == OffloadFixtures.card.count)
        #expect(review.card.bytes == OffloadFixtures.cardBytes)
        #expect(review.isUsable)
        #expect(review.bestCase == OffloadFixtures.filesBeforeDCIM)
        let resumable = try #require(review.offers.first)
        #expect(resumable.files == OffloadFixtures.filesBeforeDCIM)
        #expect(resumable.bytes == 544)
        #expect(resumable.isUsable)
        #expect(resumable.refusal == nil)
        let untouched = try #require(review.offers.last)
        #expect(!untouched.isUsable)
        #expect(untouched.refusal == .noManifest)
    }
}
