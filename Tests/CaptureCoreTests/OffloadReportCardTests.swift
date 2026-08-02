import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import CaptureCore

/// The third thing an offload leaves in every destination: the summary as a
/// PICTURE (owner item 17).
///
/// It is the artifact that actually gets handed over — dropped into a chat
/// window, looked at on a phone — so what is pinned here is that it is a real
/// PNG at the size it claims, that every ending draws one, that a bad disk
/// cannot make it grow without bound, and that the pass which reads a copy back
/// does not then report it as litter.
///
/// A separate suite from `OffloadReportTests` because it is a separate
/// deliverable with its own failure modes; the run both of them render is the
/// same one, out of `OffloadFixtures`.
struct OffloadReportCardTests {
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

    /// The card has to be a real PNG, at the size it claims, because what
    /// happens to it next is that somebody drops it into a chat window. A
    /// renderer that quietly produced zero bytes would look exactly like a
    /// renderer that worked, right up until the moment it mattered.
    @Test func theReportPictureIsADecodablePNGAtItsDeclaredSize() throws {
        let data = try #require(OffloadReportCard.png(result: result(),
                                                      run: run()))

        let source = try #require(CGImageSourceCreateWithData(data as CFData,
                                                              nil))
        #expect((CGImageSourceGetType(source) as String?)
            == UTType.png.identifier)
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        // Both axes, because the scale is what makes it readable on a phone:
        // a 1x bitmap means the scale was dropped somewhere and every hand-over
        // from then on is a soft one.
        #expect(image.width
            == Int(OffloadReportCard.width * OffloadReportCard.scale))
        #expect(image.height == Int(CardMetrics.height(problemLines: 0)
            * OffloadReportCard.scale))
    }

    /// Every ending draws, and a run with problems draws a taller card than one
    /// without — the problem list is the only variable part of the layout, so
    /// this is what says it was actually included.
    @Test func everyOutcomeDrawsAndProblemsMakeTheCardTaller() throws {
        let clean = try #require(OffloadReportCard.png(result: result(),
                                                       run: run()))
        let broken = try #require(OffloadReportCard.png(
            result: result(verified: 1,
                           mismatches: ["DCIM/A001.mov (checksum mismatch)"],
                           failure: "the volume is read-only"),
            run: run(sourceFailures: ["DCIM/A002.mov (I/O error)"])))

        #expect(height(of: broken) > height(of: clean))
        for ending in [result(verified: 2, mismatches: ["A.mov (mismatch)"]),
                       result(verified: 1, failure: "no space left"),
                       result(verified: 1, cancelled: true)] {
            #expect(OffloadReportCard.png(result: ending, run: run()) != nil,
                    "no picture for \(ending.outcome)")
        }
    }

    /// Where the checksum list is, relative to the copy — and that a
    /// destination which never got one SAYS so. The footer is a fixed line, so a
    /// missing manifest would otherwise read as a blank after the label, which
    /// somebody scanning the card takes for "there, and I did not read it".
    ///
    /// It is named as the checksum list and never as the receipt (owner item
    /// 24): the receipt is this card and the .txt beside it, both in the root
    /// of the copy, and a footer calling the `ascmhl/` file the receipt read as
    /// though the thing being handed over had been filed away in a subfolder.
    @Test func theFooterNamesTheChecksumListOrStatesThatThereIsNone() {
        var orphan = result()
        orphan.manifestURL = nil

        #expect(OffloadReportCard.checksumList(result())
            == "ascmhl/0001_CARD_A001.mhl")
        #expect(OffloadReportCard.checksumList(orphan) == "not written")
        #expect(!OffloadReportLabels.english.footerFormat.contains("receipt"))
    }

    /// The card has one line per number: the exact byte count `OffloadFormat`
    /// appends in parentheses belongs in the .txt, where somebody is checking
    /// arithmetic rather than reading a headline off a phone.
    @Test func theStatsDropTheExactByteCountTheTextKeeps() {
        #expect(OffloadFormat.bytes(64_236_544)
            == "64.2 MB (64,236,544 bytes)")
        #expect(OffloadFormat.shortBytes(64_236_544) == "64.2 MB")
        #expect(OffloadFormat.shortBytes(2_000_000_000_000) == "2.0 TB")
        // …and a count small enough to be quoted in bytes is left alone rather
        // than truncated to nothing.
        #expect(OffloadFormat.shortBytes(512) == "512 bytes")
    }

    /// A disk that lost a folder produces hundreds of problem lines, and a card
    /// four screens tall is one nobody reads the verdict on.
    @Test func theProblemListIsCappedAndSaysHowMuchItLeftOut() {
        let many = (0..<40).map { "DCIM/A\($0).mov (checksum mismatch)" }

        let shown = OffloadReportCard.shown(many)

        #expect(shown.count == 7) // the cap, plus the line that counts the rest
        #expect(shown.last?.contains("34") == true)
        // …and where the rest of them are
        #expect(shown.last?.contains(".txt") == true)
        // …and a short list is left exactly as it is
        #expect(OffloadReportCard.shown(["one", "two"]) == ["one", "two"])
        // the counting line is an injected label — the app hands it in in the
        // UI language (owner item 21), and the cap has to use what it is given
        var labels = OffloadReportLabels()
        labels.moreProblemsFormat = "…и ещё %d — см. сводку .txt"
        #expect(OffloadReportCard.shown(many, labels: labels).last
            == "…и ещё 34 — см. сводку .txt")
    }

    /// The worst thing first, the same order the .txt verdict uses.
    @Test func theProblemsAreListedWorstFirst() {
        let lines = OffloadReportCard.problems(
            result: result(verified: 1, mismatches: ["A001.mov (mismatch)"],
                           failure: "the volume is read-only"),
            run: run(sourceFailures: ["A002.mov (I/O error)"],
                     scanFailures: ["PRIVATE (Permission denied)"]))

        #expect(lines.count == 4)
        #expect(lines[0].hasPrefix("Destination failed"))
        #expect(lines[1] == "A001.mov (mismatch)")
        #expect(lines[2] == "A002.mov (I/O error)")
        #expect(lines[3] == "PRIVATE (Permission denied)")
    }

    /// The picture is written beside the .txt, under the same stem — which is
    /// also what keeps the verify pass from reporting it as litter on the disk
    /// it was written to.
    @Test func thePictureIsWrittenBesideTheSummaryAndIsNotAStray() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("takeshot-card-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let url = try OffloadReportCard.write(
            result: result(), run: run(), into: folder,
            date: Date(timeIntervalSince1970: 1_800_000_000))

        #expect(url.lastPathComponent.hasPrefix(OffloadSummary.filePrefix))
        #expect(url.pathExtension == "png")
        #expect(OffloadVerify.isReportFile(url.lastPathComponent))
        #expect(OffloadVerify.isReportFile("offload-summary_x.txt"))
        #expect(!OffloadVerify.isReportFile("DCIM/A001C001.mov"))
        #expect(try Data(contentsOf: url).count > 1000)
    }

    private func height(of png: Data) -> Int {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return 0 }
        return image.height
    }
}
