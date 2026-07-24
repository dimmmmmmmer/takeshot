import AppKit
import CaptureCore
import Foundation

/// Shift report as a paginated A4 PDF: header with the day's totals, then a
/// take table with thumbnails, TC in/out, ratings, comments and markers.
enum ShiftReport {
    private static let pageSize = CGSize(width: 595, height: 842) // A4, points
    private static let margin: CGFloat = 36
    private static let rowHeight: CGFloat = 46
    private static let thumbSize = CGSize(width: 64, height: 36)

    static func pdfData(takes: [Take], thumbnails: [UUID: NSImage],
                        project: String, camera: String) -> Data? {
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer,
                                      mediaBox: &mediaBox, nil)
        else { return nil }

        let titleFont = NSFont.boldSystemFont(ofSize: 16)
        let headFont = NSFont.boldSystemFont(ofSize: 9)
        let bodyFont = NSFont.systemFont(ofSize: 9)
        let monoFont = NSFont.monospacedDigitSystemFont(ofSize: 9,
                                                        weight: .regular)

        var y: CGFloat = 0 // distance from the TOP of the page
        var pageOpen = false

        func openPage() {
            context.beginPDFPage(nil)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context,
                                                          flipped: false)
            pageOpen = true
            y = margin
        }

        func closePage() {
            guard pageOpen else { return }
            NSGraphicsContext.current = nil
            context.endPDFPage()
            pageOpen = false
        }

        func draw(_ text: String, x: CGFloat, width: CGFloat, font: NSFont,
                  color: NSColor = .black, offset: CGFloat = 0) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let attributed = NSAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: color,
                .paragraphStyle: paragraph,
            ])
            // PDF origin is bottom-left; y counts from the top
            let height = font.pointSize + 6
            let rect = CGRect(x: x, y: pageSize.height - y - offset - height,
                              width: width, height: height)
            attributed.draw(in: rect)
        }

        // column layout: thumb | clip | TC in | TC out | dur | rating | comment
        let xThumb = margin
        let xClip = xThumb + thumbSize.width + 8
        let xTCIn = xClip + 150
        let xTCOut = xTCIn + 70
        let xDur = xTCOut + 70
        let xRating = xDur + 40
        let xComment = xRating + 42
        let commentWidth = pageSize.width - margin - xComment

        func drawTableHead() {
            draw("CLIP", x: xClip, width: 150, font: headFont, color: .darkGray)
            draw("TC IN", x: xTCIn, width: 70, font: headFont, color: .darkGray)
            draw("TC OUT", x: xTCOut, width: 70, font: headFont, color: .darkGray)
            draw("DUR", x: xDur, width: 40, font: headFont, color: .darkGray)
            draw("TAKE", x: xRating, width: 42, font: headFont, color: .darkGray)
            draw("NOTES", x: xComment, width: commentWidth, font: headFont,
                 color: .darkGray)
            y += 16
            context.setStrokeColor(NSColor.lightGray.cgColor)
            context.setLineWidth(0.5)
            context.move(to: CGPoint(x: margin, y: pageSize.height - y + 4))
            context.addLine(to: CGPoint(x: pageSize.width - margin,
                                        y: pageSize.height - y + 4))
            context.strokePath()
        }

        openPage()

        // header
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        draw("\(project.isEmpty ? "TakeShot" : project) — shift report",
             x: margin, width: pageSize.width - 2 * margin, font: titleFont,
             offset: 4)
        y += 24
        let good = takes.filter { $0.rating == .good }.count
        let bad = takes.filter { $0.rating == .bad }.count
        let total = takes.reduce(0.0) { $0 + $1.durationSeconds }
        let totalText = String(format: "%d:%02d:%02d", Int(total) / 3600,
                               (Int(total) / 60) % 60, Int(total) % 60)
        let cameraPart = camera.isEmpty ? "" : "   Cam \(camera)"
        draw("\(formatter.string(from: Date()))\(cameraPart)   "
             + "\(takes.count) takes (\(good) good, \(bad) NG)   "
             + "footage \(totalText)",
             x: margin, width: pageSize.width - 2 * margin, font: bodyFont,
             color: .darkGray)
        y += 24
        drawTableHead()

        for take in takes {
            if y + rowHeight > pageSize.height - margin {
                closePage()
                openPage()
                drawTableHead()
            }
            // thumbnail
            if let thumb = thumbnails[take.id] {
                let rect = NSRect(x: xThumb,
                                  y: pageSize.height - y - thumbSize.height - 2,
                                  width: thumbSize.width,
                                  height: thumbSize.height)
                thumb.draw(in: rect, from: .zero, operation: .sourceOver,
                           fraction: 1)
            }
            let name = take.url.deletingPathExtension().lastPathComponent
            draw(name, x: xClip, width: 150, font: bodyFont, offset: 2)
            if !take.markers.isEmpty {
                draw("⚑ \(take.markers.map(\.timecodeText).joined(separator: "  "))",
                     x: xClip, width: 150, font: NSFont.systemFont(ofSize: 7),
                     color: .orange, offset: 15)
            }
            draw(take.startTimecode?.description ?? "—", x: xTCIn, width: 70,
                 font: monoFont, offset: 2)
            draw(TakeLogExporter.endTimecode(of: take)?.description ?? "—",
                 x: xTCOut, width: 70, font: monoFont, offset: 2)
            draw(String(format: "%.1fs", take.durationSeconds), x: xDur,
                 width: 40, font: monoFont, offset: 2)
            switch take.rating {
            case .good:
                draw("● GOOD", x: xRating, width: 42, font: headFont,
                     color: NSColor(calibratedRed: 0.1, green: 0.55, blue: 0.2,
                                    alpha: 1), offset: 2)
            case .bad:
                draw("✕ NG", x: xRating, width: 42, font: headFont,
                     color: NSColor(calibratedRed: 0.75, green: 0.15, blue: 0.1,
                                    alpha: 1), offset: 2)
            case .none:
                draw("—", x: xRating, width: 42, font: bodyFont,
                     color: .lightGray, offset: 2)
            }
            draw(take.comment, x: xComment, width: commentWidth, font: bodyFont,
                 offset: 2)
            y += rowHeight
        }

        closePage()
        context.closePDF()
        return data as Data
    }
}
