import AppKit
import CaptureCore
import Foundation
import PDFKit
import Testing

@testable import TakeShotKit

/// The contact sheet is the shift report's visual sibling: the day as a
/// thumbnail grid. Like the report, it is generated once at wrap from a list
/// nobody re-checks — so what is pinned is the deterministic grid math (12
/// cells to an A4 page), that no take is dropped at a page break, and that a
/// take whose file cannot be decoded still gets its cell (with the placeholder)
/// instead of failing the whole export.
@MainActor
struct ModelContactSheetTests {
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
        let data = try #require(ContactSheet.pdfData(
            takes: takes, thumbnails: thumbnails, project: project,
            camera: camera))
        return try #require(PDFDocument(data: data), "not a readable PDF")
    }

    private func text(of document: PDFDocument) -> String {
        (0..<document.pageCount)
            .compactMap { document.page(at: $0)?.string }
            .joined(separator: "\n")
    }

    /// The grid is 3 columns by 4 rows: the twelfth take shares the first
    /// page, the thirteenth opens the second. This is the layout invariant
    /// everything else (and the operator's page count at the printer) rests on.
    @Test func twelveCellsFillAPageAndTheThirteenthOpensTheNext() throws {
        #expect(try document((1...12).map { take($0) }).pageCount == 1)
        #expect(try document((1...13).map { take($0) }).pageCount == 2)
    }

    /// A day with no takes still has to print — same contract as the report.
    @Test func anEmptyDayStillProducesAPage() throws {
        let document = try document([])
        #expect(document.pageCount == 1)
        #expect(text(of: document).contains("0 takes"))
    }

    /// The header is the shift report's, word for word except the title.
    @Test func headerCarriesTheProjectCameraAndTotals() throws {
        let takes = [take(1, rating: .good, duration: 30),
                     take(2, rating: .bad, duration: 30),
                     take(3, duration: 5)]
        let body = text(of: try document(takes, project: "Nightfall", camera: "B"))
        #expect(body.contains("Nightfall"))
        #expect(body.contains("contact sheet"))
        #expect(body.contains("Cam B"))
        #expect(body.contains("3 takes"))
        #expect(body.contains("1 good"))
        #expect(body.contains("1 bad"))
        // 30 + 30 + 5 seconds of footage
        #expect(body.contains("0:01:05"))
    }

    /// Every take reaches the paper: the cell that triggers a page break must
    /// be drawn on the new page, not skipped.
    @Test func noTakeIsLostAcrossPageBreaks() throws {
        let takes = (1...30).map { take($0) }
        let document = try document(takes)
        #expect(document.pageCount == 3, "30 takes at 12 a page is 3 pages")

        let body = text(of: document)
        let missing = takes.map(\.displayName).filter { !body.contains($0) }
        #expect(missing.isEmpty,
                "not printed: \(missing.joined(separator: ", "))")
    }

    /// Sheet pages get pinned up and passed around one by one — each carries
    /// the full header, not just the first.
    @Test func everyPageRepeatsTheHeader() throws {
        let document = try document((1...30).map { take($0) })
        for index in 0..<document.pageCount {
            let page = try #require(document.page(at: index)?.string)
            #expect(page.contains("contact sheet"),
                    "page \(index + 1) has no header")
        }
    }

    /// Each cell carries the take's key facts: start TC, duration, rating in
    /// the current vocabulary (Good/Bad), the comment, and the marker count.
    @Test func cellsCarryTCDurationRatingCommentAndMarkers() throws {
        let marker = TakeMarker(seconds: 4, timecodeText: "10:00:05:12",
                                color: "red", note: "boom in frame")
        let subject = take(1, rating: .good, comment: "soft on the wide",
                           markers: [marker, marker])
        let body = text(of: try document([subject, take(2, rating: .bad)]))
        #expect(body.contains(try #require(subject.startTimecode).description))
        #expect(body.contains("12.0s"))
        #expect(body.contains("GOOD"))
        #expect(body.contains("BAD"))
        #expect(body.contains("soft on the wide"))
        #expect(body.contains("⚑ 2"))
    }

    /// The slate leads the cell's detail line. It shares that line rather than
    /// taking one of its own because the cell height is what puts exactly 12
    /// takes on an A4 page — pinned here beside the page-count test above.
    @Test func cellsCarryTheSlateWithoutCostingAPageRow() throws {
        var slated = take(1)
        slated.slate = SlateMetadata(scene: "12A", shot: "B", take: 3)
        let body = text(of: try document([slated]))
        #expect(body.contains("12A/B T3"))
        #expect(body.contains(try #require(slated.startTimecode).description),
                "the slate displaced the timecode")

        let twelve = (1...12).map { index -> Take in
            var subject = take(index)
            subject.slate = SlateMetadata(scene: "12A", shot: "B", take: index)
            return subject
        }
        #expect(try document(twelve).pageCount == 1)
    }

    /// The sheet speaks the app language like the report does (owner item 21):
    /// title, summary and ratings all come out Russian under the Russian UI.
    @Test func theContactSheetSpeaksTheAppLanguage() throws {
        let takes = [take(1, rating: .good), take(2, rating: .bad)]
        let data = try #require(ViewRender.withLanguage(.russian) {
            ContactSheet.pdfData(takes: takes, thumbnails: [:],
                                 project: "Ночь", camera: "A")
        })
        let document = try #require(PDFDocument(data: data))
        // PDFKit extracts the bold title's lowercase Cyrillic "к" as U+0138
        // (kra): CoreGraphics reverse-maps the glyph the two code points share
        // through the font's cmap and picks the Latin one. The words on paper
        // are right — normalise the extraction artifact rather than weaken
        // the assertion (the 9pt summary line does not hit it).
        let body = text(of: document).replacingOccurrences(of: "\u{0138}",
                                                           with: "к")
        #expect(body.contains("контактный лист"), "the title is not translated")
        #expect(body.contains("Камера A"))
        #expect(body.contains("2 дублей"))
        #expect(body.contains("ГОДЕН"))
        #expect(body.contains("БРАК"))
    }

    /// End to end on real files: posters are decoded from the recorded clips
    /// for THIS export (never the panel's cache), a corrupt file and a missing
    /// file decode to nothing — their cells fall back to the placeholder — and
    /// the finished PDF lands on disk with the right page count.
    @Test func exportDecodesPostersAndSurvivesCorruptAndMissingFiles() async throws {
        let scratch = try MediaFixtures.makeDirectory("contact-sheet")
        defer { try? FileManager.default.removeItem(at: scratch) }

        var good = take(1, rating: .good, duration: 1)
        good.url = try await MediaFixtures.writeClip(
            at: scratch.appendingPathComponent("CLIP001.mov"), frames: 25)
        var corrupt = take(2, duration: 1)
        corrupt.url = try MediaFixtures.writeCorruptClip(
            at: scratch.appendingPathComponent("CLIP002.mov"))
        let missing = take(3, duration: 1) // /tmp/CLIP003.mov does not exist

        let takes = [good, corrupt, missing]
        let posters = await ContactSheet.exportThumbnails(for: takes)
        #expect(posters[good.id] != nil, "the real clip must yield a poster")
        #expect(posters[corrupt.id] == nil)
        #expect(posters[missing.id] == nil)

        let data = try #require(ContactSheet.pdfData(
            takes: takes, thumbnails: posters, project: "Film", camera: "A"))
        let url = scratch.appendingPathComponent("contacts.pdf")
        try data.write(to: url)
        let document = try #require(PDFDocument(url: url), "no PDF on disk")
        #expect(document.pageCount == 1)
        let body = text(of: document)
        for name in takes.map(\.displayName) {
            #expect(body.contains(name), "cell for \(name) is missing")
        }
    }
}
