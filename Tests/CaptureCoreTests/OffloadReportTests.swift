import Foundation
import Testing

@testable import CaptureCore

/// The two TEXT records an offload leaves behind: the manifest post re-verifies
/// the drive against, and the summary somebody reads before formatting a card.
/// The shape of both is pinned here, including the cases that quietly produce an
/// unopenable manifest — a filename with an ampersand in it — and the
/// locale-dependent formatting that would make two days' reports incomparable.
///
/// The picture written beside them is `OffloadReportCardTests`; both suites draw
/// the same run out of `OffloadFixtures`, because they are two renderings of it.
struct OffloadReportTests {
    private let creator = OffloadFixtures.reportCreator

    private func run(files: Int = 3, bytes: Int64 = 4096,
                     sourceFailures: [String] = [],
                     scanFailures: [String] = []) -> OffloadRunFacts {
        OffloadFixtures.reportRun(files: files, bytes: bytes,
                                  sourceFailures: sourceFailures,
                                  scanFailures: scanFailures)
    }

    private func result(verified: Int = 3, mismatches: [String] = [],
                        failure: String? = nil,
                        cancelled: Bool = false) -> OffloadDestinationResult {
        OffloadFixtures.reportResult(verified: verified, mismatches: mismatches,
                                     failure: failure, cancelled: cancelled)
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

    /// The whole document, to the byte.
    ///
    /// The assertions above check that the pieces are present; this one checks
    /// that nothing moved. A manifest is re-parsed by somebody else's tool
    /// months later, so indentation, element order and attribute spelling are
    /// all part of the contract, and a refactor that "only" reorganised the
    /// writer would otherwise pass every other test in this file.
    @Test func theManifestIsByteIdentical() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let entries = [OffloadEntry(relativePath: "DCIM/A001C001.mov",
                                    size: 200_000, hash: "ef46db3751d8e999")]

        let xml = OffloadMHL.xml(entries: entries, algorithm: .xxh64,
                                 creator: creator, date: date)

        #expect(xml == """
        <?xml version="1.0" encoding="UTF-8"?>
        <hashlist version="2.0" xmlns="urn:ASC:MHL:v2.0">
          <creatorinfo>
            <creationdate>\(OffloadFormat.iso8601(date))</creationdate>
            <hostname>studio-mac.local</hostname>
            <tool version="0.1.0">TakeShot</tool>
          </creatorinfo>
          <processinfo>
            <process>transfer</process>
          </processinfo>
          <hashes>
            <hash>
              <path size="200000">DCIM/A001C001.mov</path>
              <xxh64 action="original">ef46db3751d8e999</xxh64>
            </hash>
          </hashes>
        </hashlist>

        """)
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

    /// The whole report, to the byte.
    ///
    /// The label column is padded to the longest label, so renaming any one of
    /// them silently re-indents every other line; the rest of this file checks
    /// for substrings and would not notice. The two timestamps are composed
    /// through `OffloadFormat` because they carry the machine's UTC offset —
    /// everything else is literal.
    @Test func theSummaryIsByteIdentical() {
        let facts = run()

        let text = OffloadSummary.text(result: result(), run: facts)

        #expect(text == """
        TakeShot verified offload
        =========================

        Source:       /Volumes/CARD_A001
        Destination:  /Volumes/SSD1/CARD_A001
        Hash:         xxHash64 (xxh64)
        Files:        3 of 3 verified
        Card size:    4.1 kB (4,096 bytes)
        Copied:       4.1 kB (4,096 bytes)
        Started:      \(OffloadFormat.timestamp(facts.span.started))
        Finished:     \(OffloadFormat.timestamp(facts.span.finished))
        Elapsed:      15 min 30 s
        Average:      0.0 MB/s
        Manifest:     ascmhl/0001_CARD_A001.mhl
        Written by:   TakeShot 0.1.0 on studio-mac.local

        Every file listed in the manifest was written to this disk, flushed to the
        device, read back with the cache bypassed and hashed again. A file whose
        hash did not match is NOT in the manifest and is named below.

        VERDICT: all 3 files verified

        """)
    }

    @Test func theVerdictNamesTheWorstThingThatHappened() {
        let full = run()
        #expect(OffloadSummary.verdict(result: result(), run: full)
            == "all 3 files verified")
        #expect(OffloadSummary.verdict(
            result: result(verified: 2, mismatches: ["A001.mov (checksum mismatch)"]),
            run: full).hasPrefix("1 FILE(S) DID NOT MATCH"))
        #expect(OffloadSummary.verdict(
            result: result(verified: 1, failure: "no space left"),
            run: full)
            == "FAILED — no space left (1 of 3 files verified before it stopped)")
        #expect(OffloadSummary.verdict(result: result(verified: 1, cancelled: true),
                                       run: full)
            == "CANCELLED — 1 of 3 files verified; do NOT wipe the card")
        // A destination whose files all matched but where the card itself could
        // not be read completely is NOT a verified offload.
        #expect(OffloadSummary.verdict(
            result: result(),
            run: run(sourceFailures: ["A001.mov (I/O error)"]))
            .hasPrefix("INCOMPLETE"))
        // …and the same for an entry the scan could not take at all: the two
        // lists are one question, so neither may be consulted without the other.
        #expect(OffloadSummary.verdict(
            result: result(),
            run: run(scanFailures: ["PRIVATE (Permission denied)"]))
            .hasPrefix("INCOMPLETE"))
    }

    /// A failure precedes a mismatch, and both precede a cancel: the operator
    /// reads one line and has to be told the worst of it.
    @Test func aFailedDestinationOutranksItsOtherProblems() {
        let broken = result(verified: 1, mismatches: ["A001.mov (checksum mismatch)"],
                            failure: "volume disappeared", cancelled: true)

        #expect(broken.outcome == .failed)
        #expect(OffloadSummary.verdict(result: broken, run: run())
            .hasPrefix("FAILED — volume disappeared"))
    }

    @Test func theSummaryListsEveryProblemSection() {
        let text = OffloadSummary.text(
            result: result(verified: 1,
                           mismatches: ["DCIM/A001.mov (checksum mismatch)"],
                           failure: "the volume is read-only"),
            run: run(sourceFailures: ["DCIM/A002.mov (I/O error)"],
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
        let text = OffloadSummary.text(result: result(), run: run())

        #expect(text.contains("read back with the cache bypassed and hashed again"))
        #expect(text.contains("Written by:"))
        #expect(text.contains("TakeShot 0.1.0 on studio-mac.local"))
        #expect(text.contains("Manifest:"))
        #expect(text.contains("ascmhl/0001_CARD_A001.mhl"))
    }

    @Test func aMissingManifestIsStatedRatherThanOmitted() {
        var orphan = result()
        orphan.manifestURL = nil

        #expect(OffloadSummary.text(result: orphan, run: run())
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
