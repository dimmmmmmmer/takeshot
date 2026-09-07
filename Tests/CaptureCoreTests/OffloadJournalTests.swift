import Foundation
import Testing

@testable import CaptureCore

/// **A run that never reaches its manifest still leaves a way back.**
///
/// Resume recognises an earlier run by reading the newest ASC MHL generation
/// and the stamp beside it — both written by `finalize`, after the last file.
/// A run that ends the way runs actually end on set never gets there: the disk
/// is pulled, the cable is kicked, the machine sleeps. The next run then finds
/// nothing at all, says "no previous offload in this folder", and copies a card
/// that is already most of the way across. On a 2 TB card that is an hour of a
/// wrap nobody has.
///
/// So the run leaves a note as it goes. These are the two halves: that the note
/// is written and taken away at the right moments, and that the next run reads
/// it — through the same card gates the manifest goes through, and trusting
/// nothing, because every claim is still re-hashed off the destination disk
/// before a file is skipped.
struct OffloadJournalTests {
    /// A destination that stops accepting writes at the END of a run: the
    /// copies are all there, the manifest cannot be written, and `finalize`
    /// therefore never takes the note away.
    ///
    /// A read-only `ascmhl/` rather than a real unplug, for the reason
    /// `OffloadFixtures.interrupt` gives: a test must never touch a real
    /// volume, and the failure has to land at a KNOWN point.
    private static func sealManifestFolder(_ dest: URL) {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: dest.appendingPathComponent(OffloadMHL.folderName)
                .path)
    }

    private static func unsealManifestFolder(_ dest: URL) {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: dest.appendingPathComponent(OffloadMHL.folderName)
                .path)
    }

    @Test func aFinishedRunLeavesNoNoteBehind() throws {
        let source = try OffloadFixtures.scratch("journal-src")
        let dest = try OffloadFixtures.scratch("journal-dst")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: dest)
        }
        try OffloadFixtures.makeCard(at: source)
        #expect(OffloadEngine.run(OffloadFixtures.plan(source, dest))
            .isFullyVerified)
        // The manifest now states everything the note stated, and a scratch
        // file left in a folder handed to post is a question somebody has to
        // ask.
        #expect(OffloadProgressJournal.read(in: dest) == nil,
                "the running note outlived the manifest that replaced it")
    }

    /// The note exists BEFORE the run ends — which is the whole property, and
    /// is invisible from a finished run because the note is then gone.
    @Test func theNoteIsWrittenWhileTheRunIsStillGoing() throws {
        let source = try OffloadFixtures.scratch("journal-live-src")
        let dest = try OffloadFixtures.scratch("journal-live-dst")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: dest)
        }
        try OffloadFixtures.makeCard(at: source)

        let seen = JournalWatch()
        var plan = OffloadFixtures.plan(source, dest)
        plan.didWriteCopy = { _ in
            seen.record(OffloadProgressJournal.read(in: dest)?.entries.count)
        }
        #expect(OffloadEngine.run(plan).isFullyVerified)
        // The first file's hook runs before any checkpoint, so nil is expected
        // there; by the last one the note has to hold something. Asserted as
        // "the largest count seen", because the file order is the fixture's.
        #expect((seen.counts.compactMap { $0 }.max() ?? 0) > 0, """
            the note was never written during the run: \(seen.counts)
            """)
    }

    /// **The headline: a run whose manifest never landed is resumed anyway.**
    ///
    /// Cadence-independent on purpose. How many files the note holds depends on
    /// `checkpointSeconds` against the speed of the disk, and a test that fixed
    /// that number would be measuring the machine. What is asserted is the
    /// property: the note holds SOME of the card and not all of it, exactly
    /// those files are reused, and every other one is copied again.
    @Test func aRunThatNeverReachedItsManifestIsStillResumed() throws {
        let source = try OffloadFixtures.scratch("journal-resume-src")
        let dest = try OffloadFixtures.scratch("journal-resume-dst")
        defer {
            try? FileManager.default.removeItem(at: source)
            Self.unsealManifestFolder(dest)
            try? FileManager.default.removeItem(at: dest)
        }
        try OffloadFixtures.makeCard(at: source)

        // Sealed during the LAST file's write: the rest of the card still
        // copies (it lands under DCIM/, not under ascmhl/), every checkpoint
        // due after that point fails, and the manifest at the end cannot be
        // written — which is what a destination that goes away looks like from
        // inside a run.
        let written = Counter()
        var first = OffloadFixtures.plan(source, dest)
        first.didWriteCopy = { _ in
            if written.next() == OffloadFixtures.card.count {
                Self.sealManifestFolder(dest)
            }
        }
        let interrupted = OffloadEngine.run(first)
        #expect(!interrupted.isFullyVerified,
                "a destination with no manifest reported a verified offload")
        #expect(OffloadManifestReader.latest(in: dest) == nil,
                "a manifest was written after all")
        let note = try #require(OffloadProgressJournal.read(in: dest), """
            the run left neither a manifest nor a note, which is the state \
            this whole feature exists to prevent
            """)
        let noted = Set(note.entries.map(\.relativePath))
        #expect(!noted.isEmpty, "the note is empty")
        #expect(noted.count < OffloadFixtures.card.count,
                "the note holds the whole card, so it proves nothing here")

        // The disk is back. Which files must NOT be copied again, by inode: a
        // re-copy is a new file, and it would carry the same contents and the
        // same dates as the original.
        Self.unsealManifestFolder(dest)
        let before = try OffloadFixtures.inodes(under: dest)
        let resumed = OffloadEngine.run(OffloadFixtures.plan(source, dest,
                                                             resume: true))
        #expect(resumed.isFullyVerified)
        let facts = try #require(resumed.destinations.first?.resume)
        #expect(facts.claimed == noted.count,
                "\(facts.claimed) files were claimed against \(noted.count) noted")
        #expect(facts.reused == noted.count,
                "\(facts.reused) files were actually reused")

        let after = try OffloadFixtures.inodes(under: dest)
        for file in OffloadFixtures.card {
            if noted.contains(file.path) {
                #expect(before[file.path] == after[file.path],
                        "\(file.path) was copied again despite the note")
            } else {
                // …and the rest WERE copied again, which is what makes the
                // line above a distinction rather than a coincidence.
                #expect(before[file.path] != after[file.path],
                        "\(file.path) was skipped without the note claiming it")
            }
        }
    }

    /// The note is gated on the card exactly as the manifest is: another
    /// card's note claims nothing, and skipping a file on the strength of one
    /// is how footage goes missing.
    @Test func aNoteFromAnotherCardClaimsNothing() throws {
        let source = try OffloadFixtures.scratch("journal-gate-src")
        let dest = try OffloadFixtures.scratch("journal-gate-dst")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: dest)
        }
        try OffloadFixtures.makeCard(at: source)
        let scan = OffloadEngine.scan(source)
        let card = OffloadVolume(files: scan.files.count,
                                 bytes: scan.files.reduce(0) { $0 + $1.size })
        let mine = OffloadCardIdentity.of(source: source, card: card)
        let entries = scan.files.map {
            OffloadEntry(relativePath: $0.relativePath, size: $0.size,
                         hash: "0")
        }

        // Somebody else's card, at somebody else's path.
        var theirs = mine
        theirs.source = "/Volumes/OTHER"
        try OffloadProgressJournal.write(
            OffloadJournal(card: theirs, algorithm: .xxh64, entries: entries),
            into: dest)
        var offer = OffloadResume.survey(card: scan.files, identity: mine,
                                         destination: dest, algorithm: .xxh64)
        #expect(offer.claimed.isEmpty,
                "another card's note claimed \(offer.claimed.count) files")
        #expect(offer.refusal == .noManifest,
                "the refusal was \(String(describing: offer.refusal))")

        // The same card, shot on since: a fact about the card, not a fault.
        var later = mine
        later.files += 1
        try OffloadProgressJournal.write(
            OffloadJournal(card: later, algorithm: .xxh64, entries: entries),
            into: dest)
        offer = OffloadResume.survey(card: scan.files, identity: mine,
                                     destination: dest, algorithm: .xxh64)
        #expect(offer.claimed.isEmpty, "a changed card's note was claimed")

        // …and checksums of a different kind are not comparable, whichever
        // file they are written in.
        try OffloadProgressJournal.write(
            OffloadJournal(card: mine, algorithm: .sha256, entries: entries),
            into: dest)
        offer = OffloadResume.survey(card: scan.files, identity: mine,
                                     destination: dest, algorithm: .xxh64)
        #expect(offer.claimed.isEmpty, "a sha256 note was claimed by an xxh64 run")

        // The control: this card's own note, this run's algorithm, claimed.
        try OffloadProgressJournal.write(
            OffloadJournal(card: mine, algorithm: .xxh64, entries: entries),
            into: dest)
        offer = OffloadResume.survey(card: scan.files, identity: mine,
                                     destination: dest, algorithm: .xxh64)
        #expect(offer.claimed.count == entries.count,
                "this card's own note claimed \(offer.claimed.count)")
        #expect(offer.refusal == nil)
    }

    /// A note is a shortcut and never evidence: one that will not parse is the
    /// same answer as none, and costs only the copying a build without the
    /// feature would have done.
    @Test func anUnreadableNoteIsTheSameAnswerAsNone() throws {
        let dest = try OffloadFixtures.scratch("journal-junk")
        defer { try? FileManager.default.removeItem(at: dest) }
        try FileManager.default.createDirectory(
            at: dest.appendingPathComponent(OffloadMHL.folderName),
            withIntermediateDirectories: true)
        try Data("not json".utf8)
            .write(to: OffloadProgressJournal.url(in: dest))
        #expect(OffloadProgressJournal.read(in: dest) == nil)
    }
}

/// Entry counts seen from inside a run.
private final class JournalWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Int?] = []
    func record(_ count: Int?) { lock.withLock { stored.append(count) } }
    var counts: [Int?] { lock.withLock { stored } }
}

/// How many files have been written, from inside the run.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}
