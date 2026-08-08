import Foundation
import Testing

@testable import CaptureCore

/// What resume REFUSES to skip, which is the half of the feature that matters.
///
/// A resume that skips a file it should have copied does not fail loudly: it
/// produces a disk that looks complete, a manifest that agrees with it, and
/// footage that is not there. Every test here is one of those cases — a copy that
/// is short, a copy that is the right length and the wrong bytes, the write the
/// disk died in the middle of, and a manifest belonging to a different card.
///
/// The happy path is `OffloadResumeTests`; whose manifest may be believed at all
/// is `OffloadResumeIdentityTests`.
struct OffloadResumeGateTests {
    /// The file each test damages. Small, so the whole of it fits one chunk, and
    /// not the first on the card — a gate that only worked on the first file
    /// would still pass.
    private static let victim = "CLIPS/index.xml"

    // MARK: - the gate is the hash

    /// A copy that is SHORTER than the manifest says is copied again.
    ///
    /// The cheap gate, and the one a size-based resume would also catch. It is
    /// here because it is the common shape of a bad copy — a write that stopped —
    /// and because the file has to come back byte for byte at its own path rather
    /// than as a second copy beside the short one.
    @Test func aTruncatedCopyIsCopiedAgainRatherThanSkipped() throws {
        let source = try OffloadFixtures.scratch("trunc-src")
        let dest = try OffloadFixtures.scratch("trunc-dst")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: dest)
        }
        try OffloadFixtures.cardAlreadyOffloaded(from: source, to: dest)
        let copy = dest.appendingPathComponent(Self.victim)
        let whole = try Data(contentsOf: copy)
        try Data(whole.prefix(100)).write(to: copy)

        let report = OffloadEngine.run(OffloadFixtures.plan(source, dest, resume: true))

        #expect(report.isFullyVerified)
        let result = try #require(report.destinations.first)
        let resume = try #require(result.resume)
        #expect(resume.claimed == OffloadFixtures.card.count)
        #expect(resume.reused == OffloadFixtures.card.count - 1)
        #expect(resume.replaced == [Self.victim])
        #expect(result.totals.bytesWritten == 512)
        // back at its own path, whole, and not beside itself
        #expect(try Data(contentsOf: copy)
            == Data(contentsOf: source.appendingPathComponent(Self.victim)))
        #expect(!FileManager.default.fileExists(
            atPath: dest.appendingPathComponent("CLIPS/index_2.xml").path))
        #expect(try OffloadFixtures.verifyManifest(
            at: #require(result.manifestURL), root: dest).sorted()
            == OffloadFixtures.card.map(\.path).sorted())
        #expect(try OffloadFixtures.summaryText(result)
            .contains("RE-COPIED OVER AN INTERRUPTED RUN (1)"))
    }

    /// THE test for the gate: a copy of exactly the right SIZE whose bytes are
    /// wrong is copied again.
    ///
    /// A resume that compared sizes would skip this file and report the disk
    /// complete. Nothing downstream would ever catch it either — the manifest
    /// would carry the old digest and `ascmhl verify` would confirm the disk
    /// against it, because the digest and the corrupt file agree with each other.
    /// So the size is never the question: the copy is re-read off the disk with
    /// the cache bypassed and hashed.
    @Test func aCopyOfTheRightSizeWithWrongBytesIsNotTrusted() throws {
        let source = try OffloadFixtures.scratch("flip-src")
        let dest = try OffloadFixtures.scratch("flip-dst")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: dest)
        }
        try OffloadFixtures.cardAlreadyOffloaded(from: source, to: dest)
        let copy = dest.appendingPathComponent(Self.victim)
        let sizeBefore = try Data(contentsOf: copy).count
        OffloadFixtures.flipFirstByte(of: copy)
        #expect(try Data(contentsOf: copy).count == sizeBefore,
                "the fixture changed the length, so this proves nothing")

        let report = OffloadEngine.run(OffloadFixtures.plan(source, dest, resume: true))

        let result = try #require(report.destinations.first)
        #expect(result.resume?.reused == OffloadFixtures.card.count - 1)
        #expect(result.resume?.replaced == [Self.victim])
        #expect(try Data(contentsOf: copy)
            == Data(contentsOf: source.appendingPathComponent(Self.victim)))
        // and the manifest carries the CARD's digest for it, not the corrupt
        // file's — which is what makes the disk re-verifiable by anyone else
        #expect(try OffloadFixtures.verifyManifest(
            at: #require(result.manifestURL), root: dest).sorted()
            == OffloadFixtures.card.map(\.path).sorted())
    }

    /// The file that was mid-write when the disk vanished. It is on the disk, it
    /// is short, and no manifest ever listed it — the run that was writing it
    /// never got to verify it.
    ///
    /// It falls out of the claim for that reason rather than by being noticed, and
    /// this pins that it does: nothing claims it, so it is copied; and because
    /// this destination is a resumed one, the debris is replaced instead of being
    /// left beside the good copy under a `_2` name. A truncated .mov on an SSD is
    /// the outcome this codebase calls worse than a missing one — it looks like
    /// footage.
    @Test func theWriteTheDiskDiedInTheMiddleOfIsReplacedNotLeftBeside() throws {
        let source = try OffloadFixtures.scratch("partial-src")
        let dest = try OffloadFixtures.scratch("partial-dst")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: dest)
        }
        try OffloadFixtures.makeCard(at: source)
        try OffloadFixtures.interrupt(dest)
        _ = OffloadEngine.run(OffloadFixtures.plan(source, dest))
        try OffloadFixtures.reconnect(dest)
        // the write that was in flight: a third of the file, never verified and
        // so never in the manifest the interrupted run left behind
        let interrupted = "DCIM/100MEDIA/A001C001.mov"
        let partial = dest.appendingPathComponent(interrupted)
        try FileManager.default.createDirectory(
            at: partial.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try OffloadFixtures.content(70_000).write(to: partial)

        let report = OffloadEngine.run(OffloadFixtures.plan(source, dest, resume: true))

        #expect(report.isFullyVerified)
        let result = try #require(report.destinations.first)
        #expect(result.resume?.replaced == [interrupted])
        #expect(try Data(contentsOf: partial)
            == Data(contentsOf: source.appendingPathComponent(interrupted)))
        #expect(!FileManager.default.fileExists(atPath: dest
            .appendingPathComponent("DCIM/100MEDIA/A001C001_2.mov").path))
        // The disk holds the card and nothing that looks like it: the verify pass
        // reports no strays, which is the same thing said from outside.
        let checked = try OffloadVerify.run(root: dest,
                                            chunkBytes: OffloadFixtures.chunk)
        #expect(checked.isIntact)
        #expect(checked.extra.isEmpty, "strays: \(checked.extra)")
    }
}
