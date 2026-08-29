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
            // The row is measured before it is placed: a note wraps, so height
            // is a property of the take and pagination is arithmetic on it.
            let layout = page.layout(of: take)
            if page.rowOverflows(layout) {
                page.close()
                page.open()
                page.drawTableHead()
            }
            page.drawRow(take, layout: layout, thumbnail: thumbnails[take.id])
        }

        page.close()
        context.closePDF()
        return data as Data
    }
}

/// Measuring and fitting the report's free text. Pure — a function of the
/// string, the width and the font and nothing else, which is what lets a row's
/// height be known before the row is drawn.
private enum ReportText {
    /// The height the text takes when wrapped into `width`.
    static func height(of text: String, width: CGFloat,
                       font: NSFont) -> CGFloat {
        ceil(attributed(text, font: font).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
    }

    /// The longest prefix of `text` that fits `lines` wrapped lines, ending in
    /// an ellipsis whenever anything was dropped.
    ///
    /// The truncation is done to the STRING rather than left to the layout,
    /// because neither AppKit option does this: `byTruncatingTail` gives one
    /// line and stops, while word wrapping into a bounded rect drops the
    /// overflow with nothing on the paper to say that it did — which is how a
    /// note came to be cut mid-word with no ellipsis at all.
    static func fitted(_ text: String, in width: CGFloat, font: NSFont,
                       lines: Int) -> String {
        let cap = ceil(font.ascender - font.descender + font.leading)
            * CGFloat(lines) + 1
        guard height(of: text, width: width, font: font) > cap else { return text }
        var words = text.split(whereSeparator: { $0.isWhitespace })
            .map { String($0) }
        while words.count > 1 {
            words.removeLast()
            let candidate = words.joined(separator: " ") + "\u{2026}"
            if height(of: candidate, width: width, font: font) <= cap {
                return candidate
            }
        }
        // A single unbroken run with no word boundary to end on: a path, a URL,
        // or a language that does not put spaces between its words. Characters,
        // then — an eighth at a time, so a very long one converges.
        var prefix = text
        while !prefix.isEmpty {
            prefix = String(prefix.dropLast(max(1, prefix.count / 8)))
            let candidate = prefix + "\u{2026}"
            if height(of: candidate, width: width, font: font) <= cap {
                return candidate
            }
        }
        return "\u{2026}"
    }

    static func attributed(_ text: String, font: NSFont,
                           color: NSColor = .black) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: color,
            .paragraphStyle: paragraph,
        ])
    }
}

/// The paginated drawing state: the PDF context, the distance from the TOP of
/// the page, and the column layout the header and the rows share.
private final class ReportPage {
    static let pageSize = CGSize(width: 595, height: 842) // A4, points
    /// A row carrying nothing but a clip name. Rows are no longer this tall by
    /// definition — see `RowLayout`.
    static let rowHeight: CGFloat = 46
    static let margin: CGFloat = 36
    static let thumbSize = CGSize(width: 64, height: 36)

    // columns: thumb | clip | TC in | TC out | dur | OK
    static let xThumb = margin
    static let xClip = xThumb + thumbSize.width + 8
    /// The clip column absorbed the 71pt the notes column used to hold, which
    /// is also what squares the table off against the right margin:
    /// 36 + 72 + 229 + 66 + 66 + 38 + 52 = 559 = 595 − 36. It ended 71pt short
    /// of the margin before, which looked like a column had failed to print.
    static let clipWidth: CGFloat = 229
    static let xTCIn = xClip + clipWidth
    static let xTCOut = xTCIn + 66
    static let xDur = xTCOut + 66
    static let xRating = xDur + 38
    /// Wide enough for the RATING words in both languages: "● ГОДЕН" needs
    /// more than the 42pt the English "● GOOD" was laid out for, and a rating
    /// truncated to "ГОДЕ…" on the paper that leaves set is a wrong answer,
    /// not a tight one. Nothing pays for it any more: the note left the columns
    /// entirely and the clip column took the space back.
    static let ratingWidth: CGFloat = 52
    /// The slate, the markers and the note are lines INSIDE a row rather than
    /// columns, so they run from the clip column to the right margin. 451pt is
    /// six times the 71pt the note used to be laid out in.
    static let stackWidth = pageSize.width - margin - xClip
    /// One 7pt line, which is the step the slate and the markers already sat on.
    static let stackStep: CGFloat = 13
    /// Air under the last line of a row, so the rule that closes the row does
    /// not sit on the descenders of the note above it.
    static let rowPadding: CGFloat = 10
    /// A note is capped at three lines — around 270 characters at 8pt across
    /// 451pt, against the sixteen that reached the paper from the old column.
    /// Past that this sheet is the wrong place for it, and the ellipsis says so.
    static let noteLines = 3

    private let titleFont = NSFont.boldSystemFont(ofSize: 16)
    private let headFont = NSFont.boldSystemFont(ofSize: 9)
    private let bodyFont = NSFont.systemFont(ofSize: 9)
    private let monoFont = NSFont.monospacedDigitSystemFont(ofSize: 9,
                                                            weight: .regular)
    private let noteFont = NSFont.systemFont(ofSize: 8)
    private let slateFont = NSFont.boldSystemFont(ofSize: 7)
    private let markerFont = NSFont.systemFont(ofSize: 7)

    private let context: CGContext
    private var y: CGFloat = 0 // distance from the TOP of the page
    private var pageOpen = false

    init(context: CGContext) {
        self.context = context
    }

    /// Where one row's lines fall and how tall it is. Only the clip name is
    /// always there — the slate and the markers each add a line, and the note
    /// can add three — so a row's height is a function of the take rather than
    /// the constant it used to be.
    struct RowLayout {
        var slate = ""
        var markers = ""
        var note = ""
        var slateOffset: CGFloat = 0
        var markerOffset: CGFloat = 0
        var noteOffset: CGFloat = 0
        var height = ReportPage.rowHeight
    }

    /// Measures a row without drawing anything.
    func layout(of take: Take) -> RowLayout {
        var layout = RowLayout()
        // The stack under the clip name, in the order the office reads it: which
        // scene this is, what was flagged during the take, and what the operator
        // wrote after it. Each line present pushes the next one down by a step,
        // which reproduces exactly where the slate and the markers sat when they
        // were the only two.
        var next: CGFloat = Self.stackStep + 2
        layout.slate = take.slate.compact
        layout.slateOffset = next
        if !layout.slate.isEmpty { next += Self.stackStep }
        if !take.markers.isEmpty {
            layout.markers = "⚑ " + take.markers.map {
                $0.note.isEmpty ? $0.timecodeText
                    : "\($0.timecodeText) \($0.note)"
            }.joined(separator: "   ")
        }
        layout.markerOffset = next
        if !layout.markers.isEmpty { next += Self.stackStep }
        let comment = take.comment
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !comment.isEmpty {
            // Fitted WITH the pencil, because the glyph takes width off the
            // first line and fitting the bare sentence would spill a line.
            layout.note = ReportText.fitted("✎ " + comment,
                                            in: Self.stackWidth,
                                            font: noteFont,
                                            lines: Self.noteLines)
            layout.noteOffset = next
            next += ReportText.height(of: layout.note, width: Self.stackWidth,
                                      font: noteFont)
        }
        layout.height = max(Self.rowHeight, next + Self.rowPadding)
        return layout
    }

    /// This row no longer fits above the bottom margin.
    func rowOverflows(_ layout: RowLayout) -> Bool {
        y + layout.height > Self.pageSize.height - Self.margin
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

    /// The words are `ReportSummary`, shared with the contact sheet; what is
    /// left here is where they go on the page and which font they take.
    func drawHeader(takes: [Take], project: String, camera: String) {
        let header = ReportSummary.make(titleKey: "report_title", takes: takes,
                                        project: project, camera: camera)
        let width = Self.pageSize.width - 2 * Self.margin
        draw(header.title, x: Self.margin, width: width, font: titleFont,
             offset: 4)
        y += 24
        draw(header.summary, x: Self.margin, width: width, font: bodyFont,
             color: .darkGray)
        y += 24
    }

    func drawTableHead() {
        draw(L("report_col_clip"), x: Self.xClip, width: Self.clipWidth,
             font: headFont, color: .darkGray)
        draw(L("report_col_tc_in"), x: Self.xTCIn, width: 66, font: headFont,
             color: .darkGray)
        draw(L("report_col_tc_out"), x: Self.xTCOut, width: 66, font: headFont,
             color: .darkGray)
        draw(L("report_col_dur"), x: Self.xDur, width: 38, font: headFont,
             color: .darkGray)
        draw(L("report_col_ok"), x: Self.xRating, width: Self.ratingWidth, font: headFont,
             color: .darkGray)
        // No notes heading: the note is not a column any more. It is a line
        // inside the row, marked "✎" the way the markers line is marked "⚑" —
        // a glyph rather than a word repeated down the page, and one that reads
        // the same in both languages.
        y += 16
        context.setStrokeColor(NSColor.lightGray.cgColor)
        context.setLineWidth(0.5)
        context.move(to: CGPoint(x: Self.margin,
                                 y: Self.pageSize.height - y + 4))
        context.addLine(to: CGPoint(x: Self.pageSize.width - Self.margin,
                                    y: Self.pageSize.height - y + 4))
        context.strokePath()
    }

    func drawRow(_ take: Take, layout: RowLayout, thumbnail: NSImage?) {
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
        draw(name, x: Self.xClip, width: Self.clipWidth, font: bodyFont,
             offset: 2)
        // The slate under the file name, and above the markers: the production
        // office reads this table by scene, and the file name says nothing
        // about which one it is. Pure data ("12A/B T3") — no words, so the row
        // reads the same in both languages.
        if !layout.slate.isEmpty {
            draw(layout.slate, x: Self.xClip, width: Self.clipWidth,
                 font: slateFont, color: .darkGray, offset: layout.slateOffset)
        }
        if !layout.markers.isEmpty {
            draw(layout.markers, x: Self.xClip, width: Self.stackWidth,
                 font: markerFont, color: .orange, offset: layout.markerOffset)
        }
        draw(take.startTimecode?.description ?? "—", x: Self.xTCIn, width: 66,
             font: monoFont, offset: 2)
        draw(TakeLogExporter.endTimecode(of: take)?.description ?? "—",
             x: Self.xTCOut, width: 66, font: monoFont, offset: 2)
        draw(L("report_duration_fmt", take.durationSeconds), x: Self.xDur,
             width: 38, font: monoFont, offset: 2)
        drawRating(take.rating)
        // The note is a line of the row rather than a column of the table, and
        // that is the whole fix: laid out in the 71pt left over after the other
        // six columns, an operator's sentence reached the paper as sixteen
        // characters, cut mid-word (owner: "это же крайне мало").
        if !layout.note.isEmpty {
            drawNote(layout.note, at: layout.noteOffset)
        }
        y += layout.height
        drawRowRule()
    }

    /// A hairline under each row. Rows used to be a fixed 46pt and read as a
    /// grid on their own; a row whose note wrapped to three lines is twice the
    /// height of its neighbour, and without a rule the eye loses which clip a
    /// rating belongs to.
    private func drawRowRule() {
        context.setStrokeColor(NSColor.lightGray.withAlphaComponent(0.35).cgColor)
        context.setLineWidth(0.25)
        context.move(to: CGPoint(x: Self.margin, y: Self.pageSize.height - y + 5))
        context.addLine(to: CGPoint(x: Self.pageSize.width - Self.margin,
                                    y: Self.pageSize.height - y + 5))
        context.strokePath()
    }

    /// The note, which is the one thing on the sheet that wraps — drawn at the
    /// height `ReportText` measured for it, so it cannot disagree with the row
    /// height pagination was decided on.
    private func drawNote(_ text: String, at offset: CGFloat) {
        let height = ReportText.height(of: text, width: Self.stackWidth,
                                       font: noteFont)
        let rect = CGRect(x: Self.xClip,
                          y: Self.pageSize.height - y - offset - height,
                          width: Self.stackWidth, height: height)
        ReportText.attributed(text, font: noteFont, color: .darkGray)
            .draw(with: rect, options: [.usesLineFragmentOrigin,
                                        .usesFontLeading], context: nil)
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
