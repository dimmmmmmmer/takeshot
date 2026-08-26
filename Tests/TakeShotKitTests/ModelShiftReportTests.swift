import AppKit
import CaptureCore
import Foundation
import PDFKit
import Testing
@testable import TakeShotKit

/// The shift report is the piece of paper that leaves set. It is generated once,
/// at wrap, from a list nobody re-checks — so the failure that matters is a take
/// silently missing from the table (a pagination off-by-one drops exactly the
/// row that overflows) or a rating printed against the wrong clip.
@MainActor
struct ModelShiftReportTests {
    private func take(_ index: Int, rating: TakeRating = .none,
                      comment: String = "", markers: [TakeMarker] = [],
                      duration: Double = 12) -> Take {
        var take = Take(
            url: URL(fileURLWithPath: "/tmp/CLIP\(String(format: "%03d", index)).mov"),
            scene: "", roll: "001", takeNumber: index,
            startTimecode: Timecode(hours: 10, minutes: 0, seconds: index,
                                    frames: 0, fps: 25),
            durationSeconds: duration,
            recordedAt: Date(timeIntervalSince1970: 0))
        take.rating = rating
        take.comment = comment
        take.markers = markers
        return take
    }

    private func document(_ takes: [Take],
                          thumbnails: [UUID: NSImage] = [:],
                          project: String = "Film",
                          camera: String = "A") throws -> PDFDocument {
        let data = try #require(ShiftReport.pdfData(
            takes: takes, thumbnails: thumbnails, project: project,
            camera: camera))
        return try #require(PDFDocument(data: data), "not a readable PDF")
    }

    private func text(of document: PDFDocument) -> String {
        (0..<document.pageCount)
            .compactMap { document.page(at: $0)?.string }
            .joined(separator: "\n")
    }

    @Test func producesAReadableSinglePagePDFForAShortDay() throws {
        let document = try document([take(1), take(2), take(3)])
        #expect(document.pageCount == 1)
        let body = text(of: document)
        // No NOTES: the note is a line inside its row, not a column.
        for column in ["CLIP", "TC IN", "TC OUT", "DUR", "OK"] {
            #expect(body.contains(column), "column \(column) is missing")
        }
    }

    /// A day with no takes still has to print — the DIT hits export before the
    /// first setup, and returning nil would look like a broken button.
    @Test func anEmptyDayStillProducesAPage() throws {
        let document = try document([])
        #expect(document.pageCount == 1)
        #expect(text(of: document).contains("0 takes"))
    }

    /// The header is the summary the production office reads first.
    @Test func headerCarriesTheProjectCameraAndTotals() throws {
        let takes = [take(1, rating: .good, duration: 30),
                     take(2, rating: .bad, duration: 30),
                     take(3, duration: 5)]
        let body = text(of: try document(takes, project: "Nightfall", camera: "B"))
        #expect(body.contains("Nightfall"))
        #expect(body.contains("shift report"))
        #expect(body.contains("Cam B"))
        #expect(body.contains("3 takes"))
        #expect(body.contains("1 good"))
        #expect(body.contains("1 bad"))
        // 30 + 30 + 5 seconds of footage
        #expect(body.contains("0:01:05"))
    }

    @Test func fallsBackToTheAppNameWhenNoProjectIsSet() throws {
        let body = text(of: try document([take(1)], project: "", camera: ""))
        #expect(body.contains("TakeShot"))
        #expect(!body.contains("Cam "))
    }

    /// Every take reaches the paper. This is the pagination invariant: the row
    /// that triggers a page break must be drawn on the new page, not skipped.
    @Test func noTakeIsLostAcrossPageBreaks() throws {
        let takes = (1...40).map { take($0) }
        let document = try document(takes)
        #expect(document.pageCount > 1, "40 takes must not fit on one page")

        let body = text(of: document)
        let missing = takes
            .map { $0.url.deletingPathExtension().lastPathComponent }
            .filter { !body.contains($0) }
        #expect(missing.isEmpty,
                "not printed: \(missing.joined(separator: ", "))")
    }

    /// Continuation pages repeat the column head — a page of bare numbers with
    /// no headings is unreadable on set.
    @Test func everyPageRepeatsTheColumnHead() throws {
        let document = try document((1...40).map { take($0) })
        for index in 0..<document.pageCount {
            let page = try #require(document.page(at: index)?.string)
            #expect(page.contains("TC IN"),
                    "page \(index + 1) has no column head")
        }
    }

    @Test func ratingsAreLabelledPerRow() throws {
        let body = text(of: try document([
            take(1, rating: .good), take(2, rating: .bad), take(3),
        ]))
        #expect(body.contains("GOOD"))
        #expect(body.contains("BAD"))
    }

    /// Comments and markers are why the report exists at all — they are the only
    /// record of what the operator noticed during the take.
    @Test func commentsAndMarkersArePrinted() throws {
        let marker = TakeMarker(seconds: 4, timecodeText: "10:00:05:12",
                                color: "red", note: "boom in frame")
        let body = text(of: try document([
            take(1, comment: "soft on the wide", markers: [marker]),
        ]))
        #expect(body.contains("soft on the wide"))
        #expect(body.contains("10:00:05:12"))
        #expect(body.contains("boom in frame"))
    }

    /// PDF text extraction breaks a wrapped line wherever the layout broke it,
    /// so a sentence that reaches the paper whole comes back with newlines
    /// inside it. Collapsing runs of whitespace asserts that every word arrived,
    /// in order, without pinning where the wrap happens to fall.
    private func flowed(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// A real note is a sentence, not a word: this is the only free text on the
    /// report and the reason the sheet is worth reading a week later. It used to
    /// be laid out in the 71pt left over after the other six columns — about
    /// twelve characters of what the operator actually typed (owner: "заметку
    /// на дубле только 12ю символами? это же крайне мало").
    @Test func aRealSentenceOfANoteReachesThePaperWhole() throws {
        let note = "soft focus on the wide, boom shadow crossing on the pan"
        let body = flowed(text(of: try document([take(1, comment: note)])))
        #expect(body.contains(note), "the note is cut short on the paper")
    }

    /// Cyrillic is wider per character than Latin, so the language that needed
    /// the rating column widened is the one to check the note against.
    @Test func aRussianNoteReachesThePaperWhole() throws {
        let note = "мягкий фокус на общем плане, тень микрофона на панораме"
        let data = try #require(ViewRender.withLanguage(.russian) {
            ShiftReport.pdfData(takes: [take(1, comment: note)],
                                thumbnails: [:], project: "Ночь", camera: "A")
        })
        let body = flowed(text(of: try #require(PDFDocument(data: data))))
        #expect(body.contains(note), "the Russian note is cut short")
    }

    /// A note has to end somewhere, and where it ends must be visible: an
    /// operator who reads their own truncated sentence knows to open the app,
    /// while one whose words vanished silently does not know anything is gone.
    @Test func aNoteLongerThanItsRoomEndsInAnEllipsis() throws {
        let note = String(repeating: "the operator kept typing and typing ",
                          count: 12)
        let body = flowed(text(of: try document([take(1, comment: note)])))
        #expect(body.contains("the operator kept typing"),
                "none of the long note reached the paper")
        #expect(!body.contains(flowed(note)), "a 420-character note cannot fit")
        #expect(body.contains("\u{2026}"), "the note was cut with no ellipsis")
    }

    /// The note line makes a row taller than the fixed 46pt every row used to
    /// be, and row height is what pagination is arithmetic on — so the take that
    /// overflows is exactly the one at risk of being dropped.
    @Test func noTakeWithANoteIsLostAcrossPageBreaks() throws {
        let takes = (1...40).map {
            take($0, comment: "note \($0): soft on the wide, boom in the pan, "
                 + "operator asked for a second pass on this one")
        }
        let document = try document(takes)
        let body = flowed(text(of: document))
        let missing = takes
            .map { $0.url.deletingPathExtension().lastPathComponent }
            .filter { !body.contains($0) }
        #expect(missing.isEmpty,
                "not printed: \(missing.joined(separator: ", "))")
        for index in 1...40 {
            #expect(body.contains("note \(index):"),
                    "the note of take \(index) is missing")
        }
    }

    /// The out point is derived from the start TC plus the duration; printing
    /// the start twice would make every take look zero-length.
    /// The production office reads the day by scene, and the file name says
    /// nothing about which one it is. The slate line is pure data ("12A/B T3")
    /// so it reads the same in both languages, and it must not push the
    /// markers line off the row.
    @Test func rowsCarryTheSlateAlongsideTheMarkers() throws {
        var slated = take(1, markers: [TakeMarker(seconds: 2,
                                                  timecodeText: "10:00:02:00",
                                                  note: "boom")])
        slated.slate = SlateMetadata(scene: "12A", shot: "B", take: 3)
        let body = text(of: try document([slated, take(2)]))
        #expect(body.contains("12A/B T3"))
        #expect(body.contains("boom"), "the slate crowded out the markers line")
        // an unslated take prints no slate line at all
        #expect(!body.contains("T0"))
    }

    @Test func timecodeInAndOutAreBothPrintedAndDiffer() throws {
        let subject = take(1, duration: 12)
        let body = text(of: try document([subject]))
        let start = try #require(subject.startTimecode).description
        let end = try #require(TakeLogExporter.endTimecode(of: subject)).description
        #expect(body.contains(start))
        #expect(body.contains(end))
        #expect(start != end)
    }

    /// A missing thumbnail is the normal state for a take whose poster frame has
    /// not been generated yet; the row still has to draw.
    @Test func rowsDrawWithAndWithoutThumbnails() throws {
        let withThumb = take(1)
        let withoutThumb = take(2)
        let image = NSImage(size: NSSize(width: 64, height: 36))
        image.lockFocus()
        NSColor.gray.setFill()
        NSRect(x: 0, y: 0, width: 64, height: 36).fill()
        image.unlockFocus()

        let document = try document([withThumb, withoutThumb],
                                    thumbnails: [withThumb.id: image])
        let body = text(of: document)
        #expect(body.contains("CLIP001"))
        #expect(body.contains("CLIP002"))
    }
}
