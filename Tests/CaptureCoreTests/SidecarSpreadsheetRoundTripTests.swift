import Foundation
import Testing

@testable import CaptureCore

/// **The sidecars come back from a spreadsheet the way they went in.**
///
/// The stated workflow is that these files get opened in Excel or Numbers,
/// hand-edited and saved; the readers then have to take what a spreadsheet
/// writes, not only what this app writes. Every loss here was doubled by the
/// writer: `exportTakeLog` rewrites the tables from memory, so what a reader
/// dropped, the next rating press wrote back as gone.
struct SidecarSpreadsheetRoundTripTests {
    /// Excel and Numbers parse `true` as a boolean and write it back as
    /// `TRUE`; a Russian Excel writes `ИСТИНА`. A reader that knew only its
    /// own spelling un-rated every good take on the next launch.
    @Test func aSpreadsheetsOwnSpellingOfTrueIsStillAGoodTake() {
        let meta = TakeLogExporter.parseMetadata(csv: """
            File Name,Scene,Take,Good Take,Comments
            excel.mov,1,1,TRUE,hero
            russian.mov,1,2,ИСТИНА,
            ours.mov,1,3,true,
            unrated.mov,1,4,FALSE,
            french.mov,1,5,VRAI,
            """)
        #expect(meta["excel.mov"]?.rating == .good, "TRUE was not read as good")
        #expect(meta["russian.mov"]?.rating == .good, "ИСТИНА was not read as good")
        #expect(meta["ours.mov"]?.rating == .good)
        #expect(meta["unrated.mov"]?.rating == TakeRating.none)
        #expect(meta["french.mov"]?.rating == .good, "VRAI was not read as good")
    }

    /// Excel's "CSV UTF-8" puts a byte-order mark in front of the header. The
    /// markers reader finds its columns by name, and U+FEFF is not whitespace:
    /// "\u{FEFF}File Name" matched nothing and every marker of the day was
    /// read as nameless and dropped.
    @Test func aByteOrderMarkDoesNotHideTheFirstColumn() {
        let rows = TakeLogExporter.parseMarkerRows(csv: """
            \u{FEFF}File Name,Timecode,Color,Note
            A001C01.mov,01:00:10:00,orange,hit
            """)
        #expect(rows["A001C01.mov"]?.count == 1,
                "the BOM cost every marker: \(rows)")
    }

    /// The build before 8dcfd69 logged the shot as free text — "12A" — and
    /// the sidecar it wrote is still in the record folder. Read as a number
    /// the strict way that became 0, and the next edit rewrote the file with
    /// the Shot column blank; the file's own metadata was already reading the
    /// same text as shot 12. One parser now, so the two cannot disagree.
    @Test func aShotLoggedAsTextByTheEarlierBuildKeepsItsNumber() {
        let parsed = TakeLogExporter.parseSlates(csv: """
            File Name,Scene,Shot,Take,Description
            old.mov,12,12A,3,
            """)
        #expect(parsed["old.mov"]?.slate.shot == 12,
                "read as \(parsed["old.mov"]?.slate.shot ?? -1)")
        #expect(parsed["old.mov"]?.slate.take == 3)
    }

    /// …and the record's rule is not the typed field's. A cell that is not a
    /// number reads as "not logged" — the Take column's stated contract —
    /// while the panel's field keeps taking the digits out of whatever was
    /// typed into it, which is what the operator meant by "T7".
    @Test func aRecordIsReadMoreStrictlyThanATypedField() {
        for cell in ["-3", "3.5", "v2", "1e2"] {
            #expect(SlateMetadata.loggedNumber(from: cell) == 0,
                    "\(cell) read as a number in a record")
        }
        #expect(SlateMetadata.loggedNumber(from: "12A") == 12)
        #expect(SlateMetadata.number(from: "T7") == 7)
        #expect(SlateMetadata.number(from: "3.5") == 35, "the typed field lost a digit")
    }
}
