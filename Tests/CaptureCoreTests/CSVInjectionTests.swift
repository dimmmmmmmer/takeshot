import Foundation
import Testing

@testable import CaptureCore

/// What operator text does to the four CSV sidecars.
///
/// Post-production reads these files, and the only thing standing between a
/// pasted comment and a re-mapped column is `escape`. The whole `AwkwardText`
/// corpus goes through each writer and, where there is one, back through the
/// matching parser — a value that does not come back is a value the operator
/// loses on the next launch.
@Suite struct CSVInjectionTests {
    // MARK: - the frozen schema

    /// `takeshot-log.csv` is what Resolve's Media Pool → Import Metadata is
    /// mapped against, and CLAUDE.md calls its schema frozen. That was an
    /// intention rather than a fact: the header spelling was pinned, and
    /// nothing said how many columns a ROW has. A column count is what an
    /// escaping bug actually breaks.
    @Test func theResolveHeaderIsFrozenSpellingOrderAndCount() {
        let header: String = TakeLogExporter.resolveCSVHeader
        #expect(header == "File Name,Reel Name,Take,Good Take,Comments",
                "the Resolve CSV header is frozen, spelling and order")
        let columns: [String] = TakeLogExporter.parseCSVLine(header)
        #expect(columns == ["File Name", "Reel Name", "Take", "Good Take",
                            "Comments"],
                "five columns, and these five")
    }

    /// One take is one record of five fields whatever is typed into it — the
    /// half of "frozen" a header literal cannot state. A comment carrying a
    /// comma that shifted Comments into a sixth column would tell Resolve the
    /// operator's note was a different field.
    @Test func everyAwkwardValueKeepsTheLogAtOneRecordOfFiveFields() {
        // pathSafe, not all: a NUL in a file NAME reaches Foundation's URL
        // percent-encoding rather than this writer (see AwkwardText.pathSafe).
        // Every field position below still gets the whole corpus.
        for (name, value) in AwkwardText.pathSafe {
            let csv: String = TakeLogExporter.resolveCSV(takes: [
                AwkwardText.take(named: "\(value).mov", roll: value,
                                 comment: value, scene: value),
            ])
            let records: [[String]] = TakeLogExporter.parseCSVRecords(csv)
            #expect(records.count == 2,
                    "one take is one record, whatever is in it: \(name)")
            #expect(records.last?.count == 5,
                    "and that record has the frozen five fields: \(name)")
        }
    }

    // MARK: - the line breaks the writer could not see

    /// U+2028 is what a paste out of Word, Pages or a browser carries, and
    /// `flattened` used to know only the three ASCII endings while the parsers
    /// split on `Character.isNewline`, which knows all six. The comment was
    /// written with a break in it, the row became two, and the second half was
    /// a record of one field.
    @Test func aPastedLineSeparatorStaysInsideItsOwnRow() {
        let csv: String = TakeLogExporter.resolveCSV(takes: [
            AwkwardText.take(comment: "boom in\u{2028}frame"),
        ])
        #expect(TakeLogExporter.parseCSVRecords(csv).count == 2,
                "a pasted line separator does not add a row")
        let back: [String: TakeLogExporter.TakeMeta] =
            TakeLogExporter.parseMetadata(csv: csv)
        #expect(back["clip.mov"]?.comment == "boom in frame",
                "and the comment comes back whole, on one line")
    }

    /// The same break in a scene cost more, because a slate row needs five
    /// fields to be read at all: the short first half was dropped, and the
    /// operator's scene, shot and description were gone on the next scan.
    @Test func aPastedLineSeparatorInASceneDoesNotLoseTheSlateRow() {
        let csv: String = TakeLogExporter.slateCSV(takes: [
            AwkwardText.take(scene: "12\u{2028}A", shot: "B",
                             logDescription: "wide"),
        ])
        let back: [String: TakeLogExporter.SlateRow] =
            TakeLogExporter.parseSlates(csv: csv)
        let row: TakeLogExporter.SlateRow? = back["clip.mov"]
        #expect(row?.slate.scene == "12 A", "the scene survives the paste")
        #expect(row?.logDescription == "wide",
                "and so does everything filed after it")
    }

    /// Every value in the corpus, through the slate sidecar and back. Scene and
    /// shot are flattened on the way out, so the comparison is against the
    /// flattened value — what must not happen is a row that vanishes.
    @Test func everySceneAndShotSurvivesTheSlateSidecar() {
        for (name, value) in AwkwardText.nonEmpty {
            let csv: String = TakeLogExporter.slateCSV(takes: [
                AwkwardText.take(scene: value, shot: "B"),
            ])
            let back: [String: TakeLogExporter.SlateRow] =
                TakeLogExporter.parseSlates(csv: csv)
            let expected: String = TakeLogExporter.flattened(value)
                .trimmingCharacters(in: .whitespaces)
            let got: String = back["clip.mov"]?.slate.scene ?? "<row lost>"
            #expect(got.trimmingCharacters(in: .whitespaces) == expected,
                    "the scene comes back as itself: \(name)")
        }
    }

    // MARK: - the formula guard, and its inverse

    /// The apostrophe that keeps Excel from executing a cell was never taken
    /// off on the way back in, so it was not an escape but an edit: "-1 stop"
    /// came back as "'-1 stop" and stayed that way.
    @Test func aCommentBeginningWithAMinusComesBackAsItself() {
        for typed in ["-1 stop", "=1+1", "+2 frames", "@camera B"] {
            let csv: String = TakeLogExporter.resolveCSV(takes: [
                AwkwardText.take(comment: typed),
            ])
            #expect(csv.contains(",'\(typed)"),
                    "the file still guards the cell against Excel")
            let back: [String: TakeLogExporter.TakeMeta] =
                TakeLogExporter.parseMetadata(csv: csv)
            #expect(back["clip.mov"]?.comment == typed,
                    "and the operator's own text comes back unedited")
        }
    }

    /// The same apostrophe on a file NAME was worse, because the name is the
    /// lookup key: a clip called `-take3.mov` filed its marks under
    /// `'-take3.mov` and never found them again.
    @Test func aFileNameBeginningWithAMinusFindsItsMarksAgain() {
        let name: String = "-take3.mov"
        let markers: String = TakeLogExporter.markersCSV(
            takes: [], other: [name: [TakeMarker(seconds: 1, note: "hit")]])
        #expect(TakeLogExporter.parseMarkerRows(csv: markers)[name]?.count == 1,
                "the markers come back under the name the file really has")
        let ranges: String = TakeLogExporter.rangesCSV(
            [name: ClipRange(inPoint: 1, outPoint: 2)])
        #expect(TakeLogExporter.parseRanges(csv: ranges)[name] != nil,
                "and so does the loop range")
    }

    // MARK: - names that came off a card rather than out of the app

    /// A file name is only sanitized when this app made it. Anything else in
    /// the record folder can be flagged and looped, and a card's name can hold
    /// every byte but `/` and NUL — including a newline, which the writer
    /// quoted correctly and the reader then split anyway.
    @Test func everyForeignFileNameRoundTripsThroughTheSidecars() {
        for (name, value) in AwkwardText.nonEmpty {
            let file: String = "a\(value)b.mov"
            let markers: String = TakeLogExporter.markersCSV(
                takes: [], other: [file: [TakeMarker(seconds: 1, note: "x")]])
            #expect(TakeLogExporter.parseMarkerRows(csv: markers)[file] != nil,
                    "the marker is filed under the real name: \(name)")
            let ranges: String = TakeLogExporter.rangesCSV(
                [file: ClipRange(inPoint: 1, outPoint: 2)])
            #expect(TakeLogExporter.parseRanges(csv: ranges)[file] != nil,
                    "and so is the loop range: \(name)")
        }
    }

    /// The full metadata round trip, corpus-wide: rating and comment together,
    /// through the file Resolve reads.
    @Test func everyCommentAndRatingSurvivesTheLog() {
        for (name, value) in AwkwardText.pathSafeNonEmpty {
            var take: Take = AwkwardText.take(named: "a\(value)b.mov",
                                              comment: value)
            take.rating = .good
            let csv: String = TakeLogExporter.resolveCSV(takes: [take])
            // through the URL, because that is where the column comes from —
            // a lastPathComponent can hold neither a separator nor a NUL
            let key: String = take.url.lastPathComponent
            let back: TakeLogExporter.TakeMeta? =
                TakeLogExporter.parseMetadata(csv: csv)[key]
            let expected: String = TakeLogExporter.flattened(value)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(back?.comment == expected, "the comment comes back: \(name)")
            #expect(back?.rating == TakeRating.good,
                    "and so does the rating beside it: \(name)")
        }
    }

    /// The shift report is paperwork rather than a round trip, but it is still
    /// a table: fourteen columns, one row per take, whatever is typed.
    @Test func theShiftReportKeepsFourteenColumnsPerTake() {
        for (name, value) in AwkwardText.pathSafe {
            let csv: String = TakeLogExporter.reportCSV(takes: [
                AwkwardText.take(named: "\(value).mov", roll: value,
                                 comment: value, scene: value, shot: value,
                                 logDescription: value, note: value),
            ])
            let records: [[String]] = TakeLogExporter.parseCSVRecords(csv)
            #expect(records.count == 2, "one take is one row: \(name)")
            #expect(records.last?.count == 14,
                    "and the row has all fourteen columns: \(name)")
        }
    }
}
