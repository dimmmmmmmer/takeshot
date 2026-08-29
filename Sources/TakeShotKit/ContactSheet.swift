import AVFoundation
import AppKit
import CaptureCore
import CoreMedia
import Foundation

/// Contact sheet as a paginated A4 PDF: the shift report's visual sibling —
/// the same header and typography, but the day laid out as a thumbnail grid,
/// one cell per take, for reviewing a shooting day at a glance.
enum ContactSheet {
    /// Compose the PDF from already-decoded posters. Pure and synchronous —
    /// the export decodes its own via `exportThumbnails`, tests hand in
    /// whatever dictionary the case needs.
    static func pdfData(takes: [Take], thumbnails: [UUID: NSImage],
                        project: String, camera: String) -> Data? {
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: SheetPage.pageSize)
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer,
                                      mediaBox: &mediaBox, nil)
        else { return nil }

        let page = SheetPage(context: context)
        page.open()
        page.drawHeader(takes: takes, project: project, camera: camera)

        var column = 0
        for take in takes {
            if column == 0, page.rowOverflowsPage {
                page.close()
                page.open()
                // every page carries the header: contact sheet pages get
                // pinned up and passed around one by one, and a page of bare
                // frames with no project or date on it is anonymous paper
                page.drawHeader(takes: takes, project: project, camera: camera)
            }
            page.drawCell(take, thumbnail: thumbnails[take.id], column: column)
            column += 1
            if column == SheetPage.columns {
                column = 0
                page.advanceRow()
            }
        }

        page.close()
        context.closePDF()
        return data as Data
    }

    /// A poster frame per take, decoded from the recorded file for THIS
    /// export. Deliberately not the panel's `thumbnails` cache: the cache
    /// only holds what the grid happened to scroll past (and evicts past 120
    /// entries), and a sheet whose cells go blank depending on scroll history
    /// is wrong. Same frame source as the panel: the file itself — the
    /// preview LUT is never baked into a reference document (CLAUDE.md,
    /// "stills are deliverables"). A take whose file is missing or does not
    /// decode simply has no entry here; the drawing falls back to the
    /// film-strip placeholder rather than throwing or hanging.
    @MainActor
    static func exportThumbnails(for takes: [Take]) async -> [UUID: NSImage] {
        var posters: [UUID: NSImage] = [:]
        for take in takes {
            guard FileManager.default.fileExists(atPath: take.url.path)
            else { continue }
            let generator = AVAssetImageGenerator(
                asset: AVURLAsset(url: take.url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 512, height: 512)
            let time = CMTime(seconds: min(1.0, take.durationSeconds / 2),
                              preferredTimescale: 600)
            guard let (cgImage, _) = try? await generator.image(at: time)
            else { continue }
            posters[take.id] = NSImage(
                cgImage: cgImage,
                size: NSSize(width: cgImage.width, height: cgImage.height))
        }
        return posters
    }
}

/// The paginated drawing state: the PDF context, the distance from the TOP of
/// the page, and the fixed grid geometry every cell shares.
private final class SheetPage {
    static let pageSize = CGSize(width: 595, height: 842) // A4, points
    static let margin: CGFloat = 36
    static let columns = 3
    static let gutter: CGFloat = 12
    static let cellWidth = (pageSize.width - 2 * margin
        - CGFloat(columns - 1) * gutter) / CGFloat(columns)
    /// Frames are wide; the poster box is 16:9 and other rasters letterbox
    /// into it rather than stretch.
    static let thumbHeight = (cellWidth * 9 / 16).rounded()
    /// Poster plus four text lines (name, TC · duration, rating, a two-line
    /// comment). With the header this puts exactly 4 rows — 12 takes — on
    /// every A4 page, which keeps the page-count math deterministic.
    static let cellHeight = thumbHeight + 55
    static let rowGutter: CGFloat = 10

    private let titleFont = NSFont.boldSystemFont(ofSize: 16)
    private let summaryFont = NSFont.systemFont(ofSize: 9)
    private let nameFont = NSFont.boldSystemFont(ofSize: 8)
    private let detailFont = NSFont.monospacedDigitSystemFont(ofSize: 7,
                                                              weight: .regular)
    private let ratingFont = NSFont.boldSystemFont(ofSize: 7)
    private let commentFont = NSFont.systemFont(ofSize: 7)

    private let context: CGContext
    private var y: CGFloat = 0 // distance from the TOP of the page
    private var pageOpen = false

    init(context: CGContext) {
        self.context = context
    }

    /// The next grid row no longer fits above the bottom margin.
    var rowOverflowsPage: Bool {
        y + Self.cellHeight > Self.pageSize.height - Self.margin
    }

    func advanceRow() {
        y += Self.cellHeight + Self.rowGutter
    }

    func open() {
        context.beginPDFPage(nil)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context,
                                                      flipped: false)
        pageOpen = true
        y = Self.margin
    }

    func close() {
        guard pageOpen else { return }
        NSGraphicsContext.current = nil
        context.endPDFPage()
        pageOpen = false
    }

    /// One truncating text run. `lines` sizes the rect for a wrapped block
    /// (the comment); everything else is a single line.
    private func draw(_ text: String, x: CGFloat, width: CGFloat, font: NSFont,
                      color: NSColor = .black, offset: CGFloat = 0,
                      lines: Int = 1) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: color,
            .paragraphStyle: paragraph,
        ])
        // PDF origin is bottom-left; y counts from the top
        let height = (font.pointSize + 3) * CGFloat(lines) + 3
        let rect = CGRect(x: x, y: Self.pageSize.height - y - offset - height,
                          width: width, height: height)
        attributed.draw(in: rect)
    }

    /// The shift report's header, word for word except the title — the two
    /// documents leave set together and have to read as one family. That is
    /// `ReportSummary` now rather than a comment over a second copy of it;
    /// what is left here is the placement and the font.
    func drawHeader(takes: [Take], project: String, camera: String) {
        let header = ReportSummary.make(titleKey: "contact_title", takes: takes,
                                        project: project, camera: camera)
        let width = Self.pageSize.width - 2 * Self.margin
        draw(header.title, x: Self.margin, width: width, font: titleFont,
             offset: 4)
        y += 24
        draw(header.summary, x: Self.margin, width: width, font: summaryFont,
             color: .darkGray)
        y += 24
    }

    func drawCell(_ take: Take, thumbnail: NSImage?, column: Int) {
        let x = Self.margin + CGFloat(column) * (Self.cellWidth + Self.gutter)
        let poster = CGRect(x: x,
                            y: Self.pageSize.height - y - Self.thumbHeight,
                            width: Self.cellWidth, height: Self.thumbHeight)
        if let thumbnail {
            drawFitted(thumbnail, in: poster)
        } else {
            drawPlaceholder(in: poster)
        }
        let textTop = Self.thumbHeight
        draw(take.displayName, x: x, width: Self.cellWidth, font: nameFont,
             offset: textTop + 3)
        let tc = take.startTimecode?.description ?? "—"
        // The slate leads the detail line rather than taking a line of its
        // own: the cell's height puts exactly 12 takes on an A4 page, and a
        // fifth text row would silently make it 9. "12A/2 T3" is pure data,
        // so the sheet still reads the same in both languages.
        let slate = take.slate.compact
        let detail = "\(tc) · \(L("report_duration_fmt", take.durationSeconds))"
        draw(slate.isEmpty ? detail : "\(slate) · \(detail)",
             x: x, width: Self.cellWidth, font: detailFont, color: .darkGray,
             offset: textTop + 14)
        drawRating(take, x: x, offset: textTop + 25)
        if !take.comment.isEmpty {
            draw(take.comment, x: x, width: Self.cellWidth, font: commentFont,
                 color: .darkGray, offset: textTop + 36, lines: 2)
        }
    }

    /// Rating on the left, marker count on the right of the same line. The
    /// words and colors are the shift report's.
    private func drawRating(_ take: Take, x: CGFloat, offset: CGFloat) {
        switch take.rating {
        case .good:
            draw("● \(L("report_rating_good"))", x: x, width: Self.cellWidth - 34,
                 font: ratingFont,
                 color: NSColor(calibratedRed: 0.1, green: 0.55, blue: 0.2,
                                alpha: 1), offset: offset)
        case .bad:
            draw("✕ \(L("report_rating_bad"))", x: x, width: Self.cellWidth - 34,
                 font: ratingFont,
                 color: NSColor(calibratedRed: 0.75, green: 0.15, blue: 0.1,
                                alpha: 1), offset: offset)
        case .none:
            draw("—", x: x, width: Self.cellWidth - 34, font: commentFont,
                 color: .lightGray, offset: offset)
        }
        if !take.markers.isEmpty {
            draw("⚑ \(take.markers.count)", x: x + Self.cellWidth - 30,
                 width: 30, font: ratingFont, color: .orange, offset: offset)
        }
    }

    /// Letterbox rather than stretch: a 4:3 or anamorphic frame keeps its
    /// shape on the dark backing.
    private func drawFitted(_ image: NSImage, in rect: CGRect) {
        context.setFillColor(NSColor(white: 0.12, alpha: 1).cgColor)
        context.fill(rect)
        let size = image.size
        guard size.width > 0, size.height > 0 else { return }
        let scale = min(rect.width / size.width, rect.height / size.height)
        let fitted = CGRect(x: rect.midX - size.width * scale / 2,
                            y: rect.midY - size.height * scale / 2,
                            width: size.width * scale,
                            height: size.height * scale)
        image.draw(in: fitted, from: .zero, operation: .sourceOver, fraction: 1)
    }

    /// A take with no decodable poster still gets its cell: a film-strip
    /// glyph in a gray box, drawn with plain fills so it cannot itself fail.
    private func drawPlaceholder(in rect: CGRect) {
        let paper = NSColor(white: 0.92, alpha: 1).cgColor
        context.setFillColor(paper)
        context.fill(rect)
        let strip = CGRect(x: rect.midX - 21, y: rect.midY - 13,
                           width: 42, height: 26)
        context.setFillColor(NSColor(white: 0.55, alpha: 1).cgColor)
        context.fill(strip)
        // sprocket holes along both edges, then the frame window
        context.setFillColor(paper)
        for hole in 0..<5 {
            let holeX = strip.minX + 4 + CGFloat(hole) * 8
            context.fill(CGRect(x: holeX, y: strip.maxY - 5,
                                width: 3, height: 3))
            context.fill(CGRect(x: holeX, y: strip.minY + 2,
                                width: 3, height: 3))
        }
        context.fill(CGRect(x: strip.minX + 5, y: strip.minY + 8,
                            width: strip.width - 10,
                            height: strip.height - 16))
    }
}
