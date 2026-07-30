import Foundation
import Testing

@testable import CaptureCore

/// The two files an offload leaves behind. They are the whole deliverable of the
/// feature: the manifest is what post re-verifies the drive against, and the
/// summary is what somebody reads before formatting a card. So the shape of both
/// is pinned here, including the cases that quietly produce an unopenable
/// manifest — a filename with an ampersand in it — and the locale-dependent
/// formatting that would make two days' reports incomparable.
struct OffloadReportTests {
    private let creator = OffloadCreatorInfo(toolName: "TakeShot",
                                             toolVersion: "0.1.0",
                                             hostname: "studio-mac.local")

    private func context(files: Int = 3, bytes: Int64 = 4096,
                         sourceFailures: [String] = [],
                         scanFailures: [String] = []) -> OffloadSummary.Context {
        OffloadSummary.Context(
            source: URL(fileURLWithPath: "/Volumes/CARD_A001"),
            algorithm: .xxh64, creator: creator,
            started: Date(timeIntervalSince1970: 1_800_000_000),
            finished: Date(timeIntervalSince1970: 1_800_000_930),
            filesTotal: files, bytesTotal: bytes,
            scanFailures: scanFailures, sourceFailures: sourceFailures)
    }

    private func result(verified: Int = 3, mismatches: [String] = [],
                        failure: String? = nil,
                        cancelled: Bool = false) -> OffloadDestinationResult {
        OffloadDestinationResult(
            id: 0, url: URL(fileURLWithPath: "/Volumes/SSD1/CARD_A001"),
            filesVerified: verified, filesTotal: 3, bytesWritten: 4096,
            mismatches: mismatches, failure: failure,
            manifestURL: URL(fileURLWithPath:
                "/Volumes/SSD1/CARD_A001/ascmhl/0001_CARD_A001.mhl"),
            summaryURL: nil, elapsed: 930, wasCancelled: cancelled)
    }

    // MARK: - the manifest

    /// A file called `A&B <take 2>.mov` is legal on a card, and the manifest it
    /// used to produce could not be opened by anything.
    @Test func aFilenameWithMarkupCharactersStaysParseable() throws {
        let entries = [OffloadEntry(relativePath: "DCIM/A&B <take 2>.mov",
                                    size: 12, hash: "0011223344556677")]

        let xml = OffloadMHL.xml(entries: entries, algorithm: .xxh64,
                                 creator: creator, date: Date())

        let document = try XMLDocument(xmlString: xml)
        let path = try #require(document
            .nodes(forXPath: "//*[local-name()='path']").first)
        #expect(path.stringValue == "DCIM/A&B <take 2>.mov")
        #expect(xml.contains("A&amp;B &lt;take 2&gt;.mov"))
    }

    /// Cyrillic filenames come off a card as often as anything else here.
    @Test func aCyrillicFilenameSurvivesTheManifest() throws {
        let entries = [OffloadEntry(relativePath: "СЦЕНА 4/дубль_2.mov",
                                    size: 7, hash: "ef46db3751d8e999")]

        let xml = OffloadMHL.xml(entries: entries, algorithm: .xxh64,
                                 creator: creator, date: Date())

        let document = try XMLDocument(xmlString: xml)
        #expect((try document.nodes(forXPath: "//*[local-name()='path']")
            .first?.stringValue) == "СЦЕНА 4/дубль_2.mov")
    }

    /// The document ASC MHL tools expect: a versioned, namespaced hashlist with
    /// creatorinfo naming the tool, and one entry per file.
    @Test func theHashlistDeclaresItsVersionAndNamespace() throws {
        let xml = OffloadMHL.xml(entries: [], algorithm: .xxh64,
                                 creator: creator, date: Date())

        #expect(xml.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"))
        #expect(xml.contains("<hashlist version=\"2.0\" xmlns=\"urn:ASC:MHL:v2.0\">"))
        #expect(xml.contains("<tool version=\"0.1.0\">TakeShot</tool>"))
        #expect(xml.contains("<hostname>studio-mac.local</hostname>"))
        // A copy from a card to a drive is a transfer, not an in-place hash.
        #expect(xml.contains("<process>transfer</process>"))
        _ = try XMLDocument(xmlString: xml)
    }

    /// The manifest name carries its generation and the folder it describes, and
    /// nothing in it may be a path separator.
    @Test func theManifestNameIsSafeAndNumbered() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("takeshot-mhl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let name = OffloadMHL.fileName(
            in: folder, root: URL(fileURLWithPath: "/Volumes/A 001:reel/"),
            date: Date(timeIntervalSince1970: 1_800_000_000))

        #expect(name.hasPrefix("0001_A_001_reel_"))
        #expect(name.hasSuffix(".mhl"))
        #expect(!name.contains(":"))
        #expect(!name.contains("/"))
    }

    // MARK: - the summary

    @Test func theVerdictNamesTheWorstThingThatHappened() {
        let full = context()
        #expect(OffloadSummary.verdict(result: result(), context: full)
            == "all 3 files verified")
        #expect(OffloadSummary.verdict(
            result: result(verified: 2, mismatches: ["A001.mov (checksum mismatch)"]),
            context: full).hasPrefix("1 FILE(S) DID NOT MATCH"))
        #expect(OffloadSummary.verdict(
            result: result(verified: 1, failure: "no space left"),
            context: full)
            == "FAILED — no space left (1 of 3 files verified before it stopped)")
        #expect(OffloadSummary.verdict(result: result(verified: 1, cancelled: true),
                                       context: full)
            == "CANCELLED — 1 of 3 files verified; do NOT wipe the card")
        // A destination whose files all matched but where the card itself could
        // not be read completely is NOT a verified offload.
        #expect(OffloadSummary.verdict(
            result: result(),
            context: context(sourceFailures: ["A001.mov (I/O error)"]))
            .hasPrefix("INCOMPLETE"))
    }

    /// A failure precedes a mismatch, and both precede a cancel: the operator
    /// reads one line and has to be told the worst of it.
    @Test func aFailedDestinationOutranksItsOtherProblems() {
        let broken = result(verified: 1, mismatches: ["A001.mov (checksum mismatch)"],
                            failure: "volume disappeared", cancelled: true)

        #expect(broken.outcome == .failed)
        #expect(OffloadSummary.verdict(result: broken, context: context())
            .hasPrefix("FAILED — volume disappeared"))
    }

    @Test func theSummaryListsEveryProblemSection() {
        let text = OffloadSummary.text(
            result: result(verified: 1,
                           mismatches: ["DCIM/A001.mov (checksum mismatch)"],
                           failure: "the volume is read-only"),
            context: context(sourceFailures: ["DCIM/A002.mov (I/O error)"],
                             scanFailures: ["PRIVATE (Permission denied)"]))

        #expect(text.contains("DESTINATION FAILED\n  the volume is read-only"))
        #expect(text.contains("CHECKSUM MISMATCHES (1)"))
        #expect(text.contains("SOURCE PROBLEMS (1)"))
        // Not "folders": a symlink the scan refused lands in the same list, and
        // the heading has to be true of both.
        #expect(text.contains("CARD ENTRIES THAT COULD NOT BE COPIED (1)"))
        #expect(text.hasSuffix("\n"))
    }

    /// The claim the DIT is relying on has to be in writing next to the numbers,
    /// because it is the difference between this file and a copy log.
    @Test func theSummaryStatesHowTheCopiesWereVerified() {
        let text = OffloadSummary.text(result: result(), context: context())

        #expect(text.contains("read back with the cache bypassed and hashed again"))
        #expect(text.contains("Written by:"))
        #expect(text.contains("TakeShot 0.1.0 on studio-mac.local"))
        #expect(text.contains("Manifest:"))
        #expect(text.contains("ascmhl/0001_CARD_A001.mhl"))
    }

    @Test func aMissingManifestIsStatedRatherThanOmitted() {
        var orphan = result()
        orphan.manifestURL = nil

        #expect(OffloadSummary.text(result: orphan, context: context())
            .contains("NOT WRITTEN"))
    }

    // MARK: - formatting

    /// The report is read by other people months later, so none of it may change
    /// shape with the operator's regional settings.
    @Test func theNumbersAreFormattedTheSameWhereverTheyAreRead() {
        #expect(OffloadFormat.grouped(0) == "0")
        #expect(OffloadFormat.grouped(999) == "999")
        #expect(OffloadFormat.grouped(1000) == "1,000")
        #expect(OffloadFormat.grouped(64_236_544) == "64,236,544")
        #expect(OffloadFormat.bytes(512) == "512 bytes")
        #expect(OffloadFormat.bytes(2048) == "2.0 kB (2,048 bytes)")
        #expect(OffloadFormat.bytes(64_236_544) == "64.2 MB (64,236,544 bytes)")
        #expect(OffloadFormat.bytes(2_000_000_000_000)
            == "2.0 TB (2,000,000,000,000 bytes)")
        #expect(OffloadFormat.rate(189.26) == "189.3 MB/s")
        #expect(OffloadFormat.rate(0) == "0.0 MB/s")
        #expect(OffloadFormat.duration(0.5) == "0.5 s")
        #expect(OffloadFormat.duration(59.4) == "59.4 s")
        #expect(OffloadFormat.duration(92) == "1 min 32 s")
        #expect(OffloadFormat.duration(3723) == "1 h 02 min 03 s")
    }

    @Test func timestampsAreFixedFormatAndFileNameSafe() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)

        let stamp = OffloadFormat.fileStamp(date)
        #expect(!stamp.contains(":"))
        #expect(!stamp.contains(" "))
        #expect(stamp.count == "yyyy-MM-dd_HHmmss".count)
        // ISO 8601 with an offset is what MHL's creationdate is
        #expect(OffloadFormat.iso8601(date).contains("T"))
        #expect(OffloadFormat.timestamp(date).contains(":"))
    }

    /// Rates are quoted in decimal MB, as drives and offload tools do.
    @Test func theRateIsDecimalMegabytesPerSecond() {
        #expect(OffloadMetrics.megabytesPerSecond(bytes: 500_000_000, seconds: 2)
            == 250)
        #expect(OffloadMetrics.megabytesPerSecond(bytes: 1, seconds: 0) == 0)
        #expect(OffloadMetrics.megabytesPerSecond(bytes: 0, seconds: 10) == 0)
    }
}
