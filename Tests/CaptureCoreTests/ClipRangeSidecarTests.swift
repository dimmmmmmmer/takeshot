import Foundation
import Testing
@testable import CaptureCore

/// The loop-range sidecar's own format: `takeshot-ranges.csv`, keyed by file
/// name, in/out in seconds, either end allowed to be empty.
///
/// This file lands in the record folder next to the footage, which means the DIT
/// can open it in Excel and re-save it. Every parse guard here exists so that one
/// mangled line costs one clip's marks and not the day's.
struct ClipRangeSidecarTests {
    private func rows(_ csv: String) -> [String] {
        csv.split(whereSeparator: \.isNewline).map(String.init)
    }

    @Test func theSidecarHasItsOwnNameAndColumns() {
        #expect(TakeLogExporter.rangesFileName == "takeshot-ranges.csv")
        #expect(TakeLogExporter.rangesFileName != TakeLogExporter.fileName,
                "the range sidecar must not be the Resolve metadata CSV")
        #expect(TakeLogExporter.rangesFileName != TakeLogExporter.markersFileName)

        let csv = TakeLogExporter.rangesCSV(
            ["A001C001.mov": ClipRange(inPoint: 12, outPoint: 20.5)])
        #expect(rows(csv).first == "File Name,In,Out")
        #expect(rows(csv).count == 2)
    }

    /// Millisecond precision, and an unset end is an empty cell — not a 0, which
    /// would read back as a mark at the head of the clip.
    @Test func anUnsetEndpointIsAnEmptyCellRatherThanZero() {
        let csv = TakeLogExporter.rangesCSV([
            "in-only.mov": ClipRange(inPoint: 1.5, outPoint: nil),
            "out-only.mov": ClipRange(inPoint: nil, outPoint: 2.25),
        ])

        #expect(rows(csv).contains("in-only.mov,1.500,"))
        #expect(rows(csv).contains("out-only.mov,,2.250"))

        let parsed = TakeLogExporter.parseRanges(csv: csv)
        #expect(parsed["in-only.mov"] == ClipRange(inPoint: 1.5, outPoint: nil))
        #expect(parsed["out-only.mov"] == ClipRange(inPoint: nil, outPoint: 2.25))
    }

    @Test func aRangeRoundTripsThroughTheFormat() {
        let ranges = [
            "A001C001.mov": ClipRange(inPoint: 12.125, outPoint: 20.5),
            "A001C002.mov": ClipRange(inPoint: 0, outPoint: 3.007),
            "a folder, with a comma": ClipRange(inPoint: 4, outPoint: nil),
        ]

        let parsed = TakeLogExporter.parseRanges(
            csv: TakeLogExporter.rangesCSV(ranges))

        #expect(parsed == ranges)
    }

    /// A clip with no marks is not a row: the sidecar is a list of what was
    /// marked, and an empty range in it would be indistinguishable from a mark of
    /// nothing.
    @Test func aClipWithoutARangeIsNotWrittenAtAll() {
        let csv = TakeLogExporter.rangesCSV([
            "marked.mov": ClipRange(inPoint: 5, outPoint: nil),
            "cleared.mov": .unset,
        ])

        #expect(rows(csv).count == 2, "the cleared clip took a row: \(csv)")
        #expect(TakeLogExporter.parseRanges(csv: csv).keys.sorted() == ["marked.mov"])
    }

    /// Rows are written in file-name order so two runs over the same marks produce
    /// the same file — a sidecar that reshuffles itself shows up as a change in
    /// the DIT's sync every time.
    @Test func rowsAreWrittenInAStableOrder() {
        let ranges = ["C.mov": ClipRange(inPoint: 3), "A.mov": ClipRange(inPoint: 1),
                      "B.mov": ClipRange(inPoint: 2)]

        let csv = TakeLogExporter.rangesCSV(ranges)

        #expect(rows(csv) == ["File Name,In,Out", "A.mov,1.000,",
                              "B.mov,2.000,", "C.mov,3.000,"])
        #expect(csv == TakeLogExporter.rangesCSV(ranges))
    }

    /// A hand-edited file. Each of these rows is dropped on its own and the good
    /// ones still come back.
    @Test func aCorruptRowIsSkippedRatherThanFatal() {
        let csv = """
            File Name,In,Out
            good.mov,1.000,2.000
            ,5.000,6.000
            no-columns.mov
            words.mov,soon,later
            negative.mov,-4.000,2.000
            nan.mov,nan,inf
            both-empty.mov,,
            half-good.mov,oops,9.000
            also-good.mov,7.000,
            """

        let parsed = TakeLogExporter.parseRanges(csv: csv)

        #expect(parsed["good.mov"] == ClipRange(inPoint: 1, outPoint: 2))
        #expect(parsed["also-good.mov"] == ClipRange(inPoint: 7, outPoint: nil))
        // one readable end is still a mark the operator made
        #expect(parsed["half-good.mov"] == ClipRange(inPoint: nil, outPoint: 9))
        // a negative offset would seek the player somewhere it cannot go, and the
        // out point on that row is fine, so the row survives without its in point
        #expect(parsed["negative.mov"] == ClipRange(inPoint: nil, outPoint: 2))
        for dropped in ["", "no-columns.mov", "words.mov", "nan.mov",
                        "both-empty.mov"] {
            #expect(parsed[dropped] == nil, "\(dropped) should have been skipped")
        }
    }

    @Test func garbageThatIsNotACSVAtAllIsEmptyRatherThanFatal() {
        #expect(TakeLogExporter.parseRanges(csv: "").isEmpty)
        #expect(TakeLogExporter.parseRanges(csv: "\u{0}\u{1}binary rubbish").isEmpty)
    }

    @Test func writesAndRemovesTheFileInTheRecordFolder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("takeshot-ranges-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let url = try TakeLogExporter.writeRanges(
            ["A001C001.mov": ClipRange(inPoint: 8, outPoint: 9)], toDirectory: root)
        #expect(url.lastPathComponent == TakeLogExporter.rangesFileName)
        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(TakeLogExporter.parseRanges(csv: written)["A001C001.mov"]
                    == ClipRange(inPoint: 8, outPoint: 9))

        // every mark cleared: the sidecar goes, so the next launch has nothing
        // stale to restore from
        try TakeLogExporter.writeRanges(["A001C001.mov": .unset], toDirectory: root)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
