import AppKit
import CaptureCore
import Foundation

/// Shift report as a paginated A4 PDF: header with the day's totals, then a
/// take table with thumbnails, TC in/out, ratings, comments and markers.
enum ShiftReport {
    static func pdfData(takes: [Take], thumbnails: [UUID: NSImage],
                        project: String, camera: String) -> Data? {
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: ReportPage.pageSize)
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer,
                                      mediaBox: &mediaBox, nil)
        else { return nil }

        let page = ReportPage(context: context)
        page.open()
        page.drawHeader(takes: takes, project: project, camera: camera)
        page.drawTableHead()

        for take in takes {
            if page.rowOverflowsPage {
                page.close()
                page.open()
                page.drawTableHead()
            }
            page.drawRow(take, thumbnail: thumbnails[take.id])
        }

        page.close()
        context.closePDF()
        return data as Data
    }
}

/// The paginated drawing state: the PDF context, the distance from the TOP of
/// the page, and the column layout the header and the rows share.
private final class ReportPage {
    static let pageSize = CGSize(width: 595, height: 842) // A4, points
    static let margin: CGFloat = 36
    static let rowHeight: CGFloat = 46
    static let thumbSize = CGSize(width: 64, height: 36)

    // columns: thumb | clip | TC in | TC out | dur | OK | notes
    static let xThumb = margin
    static let xClip = xThumb + thumbSize.width + 8
    static let xTCIn = xClip + 158
    static let xTCOut = xTCIn + 66
    static let xDur = xTCOut + 66
    static let xRating = xDur + 38
    /// Wide enough for the RATING words in both languages: "● ГОДЕН" needs
    /// more than the 42pt the English "● GOOD" was laid out for, and a rating
    /// truncated to "ГОДЕ…" on the paper that leaves set is a wrong answer,
    /// not a tight one. The notes column pays for it — it is the one that
    /// truncates gracefully.
    static let ratingWidth: CGFloat = 52
    static let xComment = xRating + ratingWidth
    static let commentWidth = pageSize.width - margin - xComment

    private let titleFont = NSFont.boldSystemFont(ofSize: 16)
    private let headFont = NSFont.boldSystemFont(ofSize: 9)
    private let bodyFont = NSFont.systemFont(ofSize: 9)
    private let monoFont = NSFont.monospacedDigitSystemFont(ofSize: 9,
                                                            weight: .regular)

    private let context: CGContext
    private var y: CGFloat = 0 // distance from the TOP of the page
    private var pageOpen = false

    init(context: CGContext) {
        self.context = context
    }

    /// The next row no longer fits above the bottom margin.
    var rowOverflowsPage: Bool {
        y + Self.rowHeight > Self.pageSize.height - Self.margin
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

    private func draw(_ text: String, x: CGFloat, width: CGFloat, font: NSFont,
                      color: NSColor = .black, offset: CGFloat = 0) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: color,
            .paragraphStyle: paragraph,
        ])
        // PDF origin is bottom-left; y counts from the top
        let height = font.pointSize + 6
        let rect = CGRect(x: x, y: Self.pageSize.height - y - offset - height,
                          width: width, height: height)
        attributed.draw(in: rect)
    }

    func drawHeader(takes: [Take], project: String, camera: String) {
        // The report speaks the app language (owner item 21), dates included:
        // a Russian shift report with an English date reads as half-translated.
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        formatter.locale = L10n.current.documentLocale
        draw("\(project.isEmpty ? "TakeShot" : project) — \(L("report_title"))",
             x: Self.margin, width: Self.pageSize.width - 2 * Self.margin,
             font: titleFont, offset: 4)
        y += 24
        let good = takes.filter { $0.rating == .good }.count
        let bad = takes.filter { $0.rating == .bad }.count
        let total = takes.reduce(0.0) { $0 + $1.durationSeconds }
        let totalText = String(format: "%d:%02d:%02d", Int(total) / 3600,
                               (Int(total) / 60) % 60, Int(total) % 60)
        let cameraPart = camera.isEmpty ? "" : "   \(L("report_camera", camera))"
        draw("\(formatter.string(from: Date()))\(cameraPart)   "
             + "\(L("report_takes_summary", takes.count, good, bad))   "
             + "\(L("report_footage", totalText))",
             x: Self.margin, width: Self.pageSize.width - 2 * Self.margin,
             font: bodyFont, color: .darkGray)
        y += 24
    }

    func drawTableHead() {
        draw(L("report_col_clip"), x: Self.xClip, width: 158, font: headFont,
             color: .darkGray)
        draw(L("report_col_tc_in"), x: Self.xTCIn, width: 66, font: headFont,
             color: .darkGray)
        draw(L("report_col_tc_out"), x: Self.xTCOut, width: 66, font: headFont,
             color: .darkGray)
        draw(L("report_col_dur"), x: Self.xDur, width: 38, font: headFont,
             color: .darkGray)
        draw(L("report_col_ok"), x: Self.xRating, width: Self.ratingWidth, font: headFont,
             color: .darkGray)
        draw(L("report_col_notes"), x: Self.xComment, width: Self.commentWidth,
             font: headFont, color: .darkGray)
        y += 16
        context.setStrokeColor(NSColor.lightGray.cgColor)
        context.setLineWidth(0.5)
        context.move(to: CGPoint(x: Self.margin,
                                 y: Self.pageSize.height - y + 4))
        context.addLine(to: CGPoint(x: Self.pageSize.width - Self.margin,
                                    y: Self.pageSize.height - y + 4))
        context.strokePath()
    }

    func drawRow(_ take: Take, thumbnail: NSImage?) {
        // thumbnail
        if let thumb = thumbnail {
            let rect = NSRect(x: Self.xThumb,
                              y: Self.pageSize.height - y - Self.thumbSize.height - 2,
                              width: Self.thumbSize.width,
                              height: Self.thumbSize.height)
            thumb.draw(in: rect, from: .zero, operation: .sourceOver,
                       fraction: 1)
        }
        let name = take.url.deletingPathExtension().lastPathComponent
        draw(name, x: Self.xClip, width: 158, font: bodyFont, offset: 2)
        if !take.markers.isEmpty {
            let flags = take.markers.map {
                $0.note.isEmpty ? $0.timecodeText : "\($0.timecodeText) \($0.note)"
            }.joined(separator: "   ")
            draw("⚑ \(flags)", x: Self.xClip,
                 width: Self.pageSize.width - Self.margin - Self.xClip,
                 font: NSFont.systemFont(ofSize: 7),
                 color: .orange, offset: 15)
        }
        draw(take.startTimecode?.description ?? "—", x: Self.xTCIn, width: 66,
             font: monoFont, offset: 2)
        draw(TakeLogExporter.endTimecode(of: take)?.description ?? "—",
             x: Self.xTCOut, width: 66, font: monoFont, offset: 2)
        draw(L("report_duration_fmt", take.durationSeconds), x: Self.xDur,
             width: 38, font: monoFont, offset: 2)
        drawRating(take.rating)
        draw(take.comment, x: Self.xComment, width: Self.commentWidth,
             font: bodyFont, offset: 2)
        y += Self.rowHeight
    }

    private func drawRating(_ rating: TakeRating) {
        switch rating {
        case .good:
            draw("● \(L("report_rating_good"))", x: Self.xRating, width: Self.ratingWidth,
                 font: headFont,
                 color: NSColor(calibratedRed: 0.1, green: 0.55, blue: 0.2,
                                alpha: 1), offset: 2)
        case .bad:
            draw("✕ \(L("report_rating_bad"))", x: Self.xRating, width: Self.ratingWidth,
                 font: headFont,
                 color: NSColor(calibratedRed: 0.75, green: 0.15, blue: 0.1,
                                alpha: 1), offset: 2)
        case .none:
            draw("—", x: Self.xRating, width: Self.ratingWidth, font: bodyFont,
                 color: .lightGray, offset: 2)
        }
    }
}
