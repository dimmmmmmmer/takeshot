import Foundation
import Testing

@testable import CaptureCore

/// Checking a disk against the manifest an offload left on it.
///
/// Every fixture here is a REAL offload run first — the manifest under test is
/// the one `OffloadMHL` writes, not a hand-rolled sample of what it is thought
/// to write. A reader that only ever parses its own idea of the format is the
/// bug this feature would fail with on set, months after anyone could still
/// remember what the file was supposed to look like.
@Suite struct OffloadVerifyTests {
    /// A card, and a disk it has been offloaded to. The disk is what gets
    /// verified; the card is kept so a test can compare against the original.
    private struct Offloaded {
        var card: URL
        var disk: URL

        func remove() {
            for url in [card, disk] {
                try? FileManager.default.removeItem(at: url)
            }
        }

        func copy(_ relativePath: String) -> URL {
            disk.appendingPathComponent(relativePath)
        }
    }

    private func offload(_ name: String,
                         algorithm: OffloadHashAlgorithm = .xxh64) throws
        -> Offloaded {
        let card = try OffloadFixtures.scratch("\(name)-card")
        try OffloadFixtures.makeCard(at: card)
        let disk = try OffloadFixtures.scratch("\(name)-disk")
        let report = OffloadEngine.run(OffloadPlan(
            source: card, destinations: [disk], algorithm: algorithm,
            chunkBytes: OffloadFixtures.chunk))
        #expect(report.isFullyVerified, "the fixture offload itself failed")
        return Offloaded(card: card, disk: disk)
    }

    private func verify(_ disk: URL) throws -> OffloadVerifyReport {
        try OffloadVerify.run(root: disk, chunkBytes: OffloadFixtures.chunk)
    }

    // MARK: - the disk is what the manifest says

    /// The whole point: a disk that came back untouched reads back clean.
    ///
    /// Including that the three files the offload wrote BESIDE the copy — its
    /// own manifest, its summary and the picture of that summary — are not
    /// reported as strays. None of them can be in the manifest (it cannot list
    /// itself, and both summaries are written after it), so a naive subtraction
    /// accuses the report of being litter on every single run, and a warning
    /// that is always on is a warning nobody reads.
    @Test func anUntouchedDiskVerifiesAgainstItsOwnManifest() throws {
        let fixture = try offload("green")
        defer { fixture.remove() }

        let report = try verify(fixture.disk)

        #expect(report.isIntact)
        #expect(report.verified.count == OffloadFixtures.card.count)
        #expect(report.mismatched.isEmpty)
        #expect(report.missing.isEmpty)
        #expect(report.extra.isEmpty,
                "reported as strays: \(report.extra.joined(separator: ", "))")
        #expect(report.scanFailures.isEmpty)
        #expect(report.algorithm == .xxh64)
        #expect(report.filesListed == OffloadFixtures.card.count)
        // every byte of the card was actually re-read, not assumed
        #expect(report.bytesRead
            == OffloadFixtures.card.reduce(0) { $0 + Int64($1.bytes) })
    }

    /// Where the offload leaves each of its three files, and that the verify
    /// tool still finds every one of them (owner item 24).
    ///
    /// The receipt — the .txt and the picture — is in the ROOT of the copy,
    /// not in a folder of its own: it is read by a person, who should find it
    /// by opening the copy. The manifest is the one artifact that IS in a
    /// subfolder, `ascmhl/`, because that is where the ASC MHL spec puts it and
    /// where every tool that re-verifies the disk looks. Both halves are held
    /// here, because moving either one silently breaks the other end: a receipt
    /// anywhere but the root is reported as a stray by `isReportFile`, and a
    /// manifest anywhere but `ascmhl/` is not found by the reader at all.
    @Test func theReceiptIsInTheRootAndTheManifestInItsSpecFolder() throws {
        let card = try OffloadFixtures.scratch("receipt-card")
        try OffloadFixtures.makeCard(at: card)
        let disk = try OffloadFixtures.scratch("receipt-disk")
        defer {
            try? FileManager.default.removeItem(at: card)
            try? FileManager.default.removeItem(at: disk)
        }

        let run = OffloadEngine.run(OffloadPlan(
            source: card, destinations: [disk],
            chunkBytes: OffloadFixtures.chunk))

        let result = try #require(run.destinations.first)
        let summary = try #require(result.summaryURL)
        let picture = try #require(result.imageURL)
        let manifest = try #require(result.manifestURL)
        #expect(summary.deletingLastPathComponent().path == disk.path,
                "the summary landed in \(summary.deletingLastPathComponent())")
        #expect(picture.deletingLastPathComponent().path == disk.path,
                "the picture landed in \(picture.deletingLastPathComponent())")
        #expect(manifest.deletingLastPathComponent().lastPathComponent
            == OffloadMHL.folderName)
        #expect(manifest.deletingLastPathComponent()
            .deletingLastPathComponent().path == disk.path)

        // …and the verify tool reads the manifest out of `ascmhl/` and does not
        // mistake either half of the receipt for litter left on the disk.
        let report = try verify(disk)
        #expect(report.manifest == manifest)
        #expect(report.isIntact)
        #expect(report.extra.isEmpty,
                "reported as strays: \(report.extra.joined(separator: ", "))")
        #expect(OffloadVerify.isReportFile(summary.lastPathComponent))
        #expect(OffloadVerify.isReportFile(picture.lastPathComponent))
    }

    /// The algorithm comes from the manifest, not from a default: a disk
    /// offloaded under a SHA-256 delivery spec has to verify months later
    /// without anybody remembering which box was ticked that day.
    @Test func theChecksumIsTheOneTheManifestNames() throws {
        let fixture = try offload("sha", algorithm: .sha256)
        defer { fixture.remove() }

        let report = try verify(fixture.disk)

        #expect(report.algorithm == .sha256)
        #expect(report.isIntact)
    }

    // MARK: - the four ways it is not

    /// One byte flipped in place: same length, same name, same date. This is
    /// exactly the failure a byte-count comparison or a folder diff cannot see,
    /// and the whole reason the manifest carries hashes at all.
    @Test func aFlippedByteIsReportedAgainstTheFileItIsIn() throws {
        let fixture = try offload("flip")
        defer { fixture.remove() }
        let victim = "DCIM/100MEDIA/A001C001.mov"
        OffloadFixtures.flipFirstByte(of: fixture.copy(victim))

        let report = try verify(fixture.disk)

        #expect(!report.isIntact)
        #expect(report.mismatched.map(\.relativePath) == [victim])
        #expect(report.mismatched.first?.reason == "checksum mismatch")
        // and the rest of the disk is still reported as fine — a single bad
        // file does not condemn the other four
        #expect(report.verified.count == OffloadFixtures.card.count - 1)
        #expect(report.missing.isEmpty)
    }

    /// A copy that was cut short reads as a mismatch too, but the reason says
    /// how short — the operator has to be able to tell "one bad sector" from
    /// "this file never finished landing" without opening either.
    @Test func aTruncatedCopySaysSoRatherThanJustNotMatching() throws {
        let fixture = try offload("short")
        defer { fixture.remove() }
        let victim = "CLIPS/index.xml"
        let handle = try FileHandle(forWritingTo: fixture.copy(victim))
        try handle.truncate(atOffset: 100)
        try handle.close()

        let report = try verify(fixture.disk)

        let fault = try #require(report.mismatched.first)
        #expect(fault.relativePath == victim)
        #expect(fault.reason.contains("100"), "reason: \(fault.reason)")
        #expect(fault.reason.contains("512"), "reason: \(fault.reason)")
    }

    /// A file the manifest lists and the disk does not have. Distinct from a
    /// mismatch on purpose: a mismatch means there is something there to
    /// investigate, and this means the footage is gone.
    @Test func aDeletedFileIsMissingRatherThanMismatched() throws {
        let fixture = try offload("gone")
        defer { fixture.remove() }
        let victim = "DCIM/100MEDIA/sub/deep/A001C003.mov"
        try FileManager.default.removeItem(at: fixture.copy(victim))

        let report = try verify(fixture.disk)

        #expect(!report.isIntact)
        #expect(report.missing == [victim])
        #expect(report.mismatched.isEmpty)
        #expect(report.verified.count == OffloadFixtures.card.count - 1)
        // the manifest still lists it, so the total does not shrink — "4 of 5"
        // is the sentence, and it needs both numbers
        #expect(report.filesListed == OffloadFixtures.card.count)
    }

    /// Something on the disk that no manifest accounts for.
    ///
    /// Reported, and NOT a fault: a LUT or a sound roll dropped beside the
    /// footage is a normal afternoon, and every file the manifest lists is still
    /// exactly what it says it is. What the list is for is the other case — a
    /// second card offloaded into this folder whose own manifest has since been
    /// deleted, which is footage nothing is verifying.
    @Test func aStrayFileIsReportedWithoutCondemningTheDisk() throws {
        let fixture = try offload("stray")
        defer { fixture.remove() }
        let stray = "DCIM/100MEDIA/scratch.txt"
        try Data("not from the card".utf8).write(to: fixture.copy(stray))

        let report = try verify(fixture.disk)

        #expect(report.extra == [stray])
        #expect(report.isIntact, "a stray file does not make the footage wrong")
        #expect(report.verified.count == OffloadFixtures.card.count)
        #expect(report.mismatched.isEmpty)
        #expect(report.missing.isEmpty)
    }

    // MARK: - folders that cannot be checked at all

    /// Pointing the tool at the wrong folder is the mistake an operator makes
    /// first, and it has to say so rather than report an empty disk as verified.
    @Test func aFolderThatWasNeverOffloadedIsAClearError() throws {
        let plain = try OffloadFixtures.scratch("no-manifest")
        defer { try? FileManager.default.removeItem(at: plain) }
        try OffloadFixtures.makeCard(at: plain)

        #expect(throws: OffloadVerifyError.noManifest(plain.lastPathComponent)) {
            try OffloadVerify.run(root: plain)
        }
        let error = OffloadVerifyError.noManifest("CARD_A001")
        #expect(error.errorDescription?.contains("CARD_A001") == true)
    }

    /// An `ascmhl` folder holding something that is not a hashlist. Refused with
    /// the file named — "it did not parse" without saying which file is a bug
    /// report nobody can act on.
    @Test func aManifestThatWillNotParseIsRefusedByName() throws {
        let disk = try OffloadFixtures.scratch("broken-manifest")
        defer { try? FileManager.default.removeItem(at: disk) }
        let folder = disk.appendingPathComponent(OffloadMHL.folderName)
        try FileManager.default.createDirectory(at: folder,
                                                withIntermediateDirectories: true)
        try Data("<hashlist><hashes>".utf8)
            .write(to: folder.appendingPathComponent("0001_disk.mhl"))

        #expect(throws: OffloadVerifyError.self) {
            try OffloadVerify.run(root: disk)
        }
    }

    /// A manifest from another tool, hashed with something this build cannot
    /// compute. Refused whole rather than verified in part: a report that
    /// silently skipped the files it did not understand would be read as a clean
    /// bill of health for all of them.
    @Test func aManifestHashedWithSomethingElseIsRefused() throws {
        let disk = try OffloadFixtures.scratch("md5-manifest")
        defer { try? FileManager.default.removeItem(at: disk) }
        let folder = disk.appendingPathComponent(OffloadMHL.folderName)
        try FileManager.default.createDirectory(at: folder,
                                                withIntermediateDirectories: true)
        let document = """
            <?xml version="1.0" encoding="UTF-8"?>
            <hashlist version="2.0" xmlns="urn:ASC:MHL:v2.0">
              <hashes>
                <hash>
                  <path size="9">A001C002.mov</path>
                  <md5 action="original">0cc175b9c0f1b6a831c399e269772661</md5>
                </hash>
              </hashes>
            </hashlist>
            """
        try Data(document.utf8)
            .write(to: folder.appendingPathComponent("0001_disk.mhl"))

        #expect(throws: OffloadVerifyError.unsupportedHash(name: "0001_disk.mhl",
                                                          found: "md5")) {
            try OffloadVerify.run(root: disk)
        }
    }

    // MARK: - which manifest

    /// A folder offloaded to twice keeps both generations, and only the newest
    /// lists what is actually on the disk now. Verified against `0001` instead,
    /// every file the second run added reads as a stray and every file it
    /// renamed reads as missing — the tool would report a healthy disk as a
    /// disaster.
    @Test func theNewestGenerationOfTheManifestIsTheOneUsed() throws {
        let fixture = try offload("generations")
        defer { fixture.remove() }
        // the same card again into the same folder: `begin` never clobbers, so
        // this lands as A001C001_2.mov and friends, and writes 0002_*.mhl
        let second = OffloadEngine.run(OffloadPlan(
            source: fixture.card, destinations: [fixture.disk],
            chunkBytes: OffloadFixtures.chunk))
        #expect(second.isFullyVerified)

        let report = try verify(fixture.disk)

        #expect(report.manifest.lastPathComponent.hasPrefix("0002_"))
        #expect(report.verified.count == OffloadFixtures.card.count)
        // the first generation's files are on the disk and in no CURRENT
        // manifest, which is exactly what a stray is
        #expect(report.extra.count == OffloadFixtures.card.count)
        #expect(report.missing.isEmpty)
        #expect(report.isIntact)
    }

    // MARK: - stopping

    /// A pass the operator stopped is not a verified disk, however much of it
    /// was read before the button went down.
    @Test func aCancelledPassNeverReportsTheDiskAsIntact() throws {
        let fixture = try offload("cancelled")
        defer { fixture.remove() }
        let token = OffloadCancellation()
        token.cancel()

        let report = try OffloadVerify.run(root: fixture.disk,
                                           cancellation: token,
                                           chunkBytes: OffloadFixtures.chunk)

        #expect(report.wasCancelled)
        #expect(!report.isIntact)
        #expect(report.verified.isEmpty)
        // and no stray list either: a complete walk of the disk beside a check
        // that stopped at the first file reads as though the walk had found
        // something the check missed
        #expect(report.extra.isEmpty)
    }
}
