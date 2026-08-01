import CoreGraphics
import CoreText
import Foundation

/// The drawing state behind `OffloadReportCard`: the context, the distance from
/// the TOP of the card, and the sections in the order they are read.
///
/// CoreText rather than AppKit's `NSAttributedString.draw(in:)` — CaptureCore
/// has no AppKit dependency and is not going to grow one for a report. Every
/// measurement it uses lives in `CardMetrics`, so this file reads as what is on
/// the card rather than as arithmetic.
final class OffloadReportCanvas {
    private let context: CGContext
    private let height: CGFloat
    /// The card's labels in the operator's language (see `OffloadReportLabels`)
    /// — the same set the .txt beside it was written with.
    private let labels: OffloadReportLabels
    /// Distance from the top of the card. CG's origin is bottom-left; every
    /// draw converts once, in `draw(_:_:x:maxWidth:)`, rather than at each of
    /// the two dozen call sites.
    private var y = CardMetrics.margin

    init(context: CGContext, height: CGFloat,
         labels: OffloadReportLabels = .english) {
        self.context = context
        self.height = height
        self.labels = labels
    }

    func draw(result: OffloadDestinationResult, run: OffloadRunFacts,
              problems: [String]) {
        fillBackground()
        drawBrand()
        drawHeadline(result)
        drawVerdict(result: result, run: run)
        drawStats(result: result, run: run)
        drawFacts(run: run)
        drawProblems(problems)
        drawFooter(result: result, run: run)
    }

    // MARK: - sections

    private func fillBackground() {
        context.setFillColor(CardInk.background)
        context.fill(CGRect(x: 0, y: 0, width: OffloadReportCard.width,
                            height: height))
    }

    private func drawBrand() {
        draw(labels.brand,
             CardTextStyle(size: CardMetrics.brandSize, bold: true,
                           color: CardInk.secondary))
        y += CardMetrics.brandBlock
    }

    private func drawHeadline(_ result: OffloadDestinationResult) {
        draw(result.url.lastPathComponent,
             CardTextStyle(size: CardMetrics.headlineSize, bold: true,
                           color: CardInk.primary))
        y += CardMetrics.headlineBlock
        draw(result.url.path,
             CardTextStyle(size: CardMetrics.pathSize,
                           color: CardInk.secondary))
        y += CardMetrics.pathBlock + 12
    }

    /// The one line somebody reads before formatting a card, on a plate in its
    /// own colour with a solid bar down the side — the same shape as the result
    /// card in the sheet, which is where the operator saw it first.
    private func drawVerdict(result: OffloadDestinationResult,
                             run: OffloadRunFacts) {
        let tint = CardInk.verdict(result.outcome)
        let top = height - y - CardMetrics.bannerHeight
        let plate = CGRect(x: CardMetrics.margin, y: top,
                           width: CardMetrics.textWidth,
                           height: CardMetrics.bannerHeight)
        fill(plate, color: CardInk.plate(tint), radius: CardMetrics.bannerRadius)
        fill(CGRect(x: plate.minX, y: plate.minY, width: 4,
                    height: plate.height), color: tint, radius: 2)
        y += 19
        let inset = CardMetrics.bannerTextInset
        draw(OffloadSummary.verdict(result: result, run: run,
                                    labels: labels).uppercased(),
             CardTextStyle(size: CardMetrics.verdictSize, bold: true,
                           color: tint),
             x: CardMetrics.margin + inset,
             maxWidth: CardMetrics.textWidth - 2 * inset)
        y += CardMetrics.bannerHeight - 19 + 26
    }

    /// Files, bytes, time, speed — the four numbers a DIT is asked for, as four
    /// columns of a label over a value.
    private func drawStats(result: OffloadDestinationResult,
                           run: OffloadRunFacts) {
        let cells = [
            (labels.statFiles, String(format: labels.statFilesFormat,
                                      result.totals.filesVerified,
                                      run.card.files)),
            (labels.statCopied,
             OffloadReportCard.shortBytes(result.totals.bytesWritten)),
            (labels.statTime, OffloadFormat.duration(result.totals.elapsed,
                                                     labels: labels)),
            (labels.statSpeed,
             OffloadFormat.rate(result.totals.megabytesPerSecond)),
        ]
        drawColumns(cells.map(\.0),
                    CardTextStyle(size: CardMetrics.labelSize, bold: true,
                                  color: CardInk.secondary))
        y += CardMetrics.statLabelBlock
        drawColumns(cells.map(\.1),
                    CardTextStyle(size: CardMetrics.valueSize, bold: true,
                                  color: CardInk.primary))
        y += CardMetrics.statValueBlock + CardMetrics.gap
    }

    private func drawColumns(_ cells: [String], _ style: CardTextStyle) {
        let step = CardMetrics.textWidth / CGFloat(CardMetrics.statColumns)
        for (index, cell) in cells.enumerated() {
            draw(cell, style, x: CardMetrics.margin + CGFloat(index) * step,
                 maxWidth: step - 12)
        }
    }

    private func drawFacts(run: OffloadRunFacts) {
        let rows = [(labels.source, run.source.path),
                    (labels.started, OffloadFormat.timestamp(run.span.started)),
                    (labels.finished, OffloadFormat.timestamp(run.span.finished))]
        let label = CardMetrics.factLabelWidth
        for row in rows {
            draw(row.0, CardTextStyle(size: CardMetrics.bodySize,
                                      color: CardInk.secondary),
                 x: CardMetrics.margin, maxWidth: label)
            draw(row.1, CardTextStyle(size: CardMetrics.bodySize,
                                      color: CardInk.primary),
                 x: CardMetrics.margin + label,
                 maxWidth: CardMetrics.textWidth - label)
            y += CardMetrics.lineHeight
        }
        y += CardMetrics.gap
    }

    private func drawProblems(_ problems: [String]) {
        guard !problems.isEmpty else { return }
        draw("\(labels.problemsHeading) (\(problems.count))",
             CardTextStyle(size: CardMetrics.labelSize, bold: true,
                           color: CardInk.verdict(.mismatched)))
        y += CardMetrics.problemsHeadBlock
        for problem in problems {
            draw(problem, CardTextStyle(size: CardMetrics.bodySize,
                                        color: CardInk.primary))
            y += CardMetrics.lineHeight
        }
        y += 10
    }

    /// Who made it, when, and where the machine-readable receipt is. The
    /// checksum list is named here rather than in the headline on purpose: the
    /// person holding this picture cares about the verdict, and the tool that
    /// cares about the manifest can find it by its folder.
    private func drawFooter(result: OffloadDestinationResult,
                            run: OffloadRunFacts) {
        rule()
        y += CardMetrics.footerRuleBlock
        draw(String(format: labels.footerFormat, run.creator.toolName,
                    run.creator.toolVersion, run.creator.hostname,
                    run.algorithm.displayName,
                    OffloadReportCard.receipt(result, labels: labels)),
             CardTextStyle(size: CardMetrics.labelSize,
                           color: CardInk.secondary))
    }

    // MARK: - primitives

    private func draw(_ string: String, _ style: CardTextStyle,
                      x: CGFloat = CardMetrics.margin,
                      maxWidth: CGFloat = CardMetrics.textWidth) {
        let ctLine = line(fitted(string, style, maxWidth: maxWidth), style)
        var ascent: CGFloat = 0
        _ = CTLineGetTypographicBounds(ctLine, &ascent, nil, nil)
        context.textPosition = CGPoint(x: x, y: height - y - ascent)
        CTLineDraw(ctLine, context)
    }

    private func rule() {
        context.setStrokeColor(CardInk.rule)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: CardMetrics.margin, y: height - y))
        context.addLine(to: CGPoint(
            x: OffloadReportCard.width - CardMetrics.margin, y: height - y))
        context.strokePath()
    }

    private func fill(_ rect: CGRect, color: CGColor, radius: CGFloat) {
        context.setFillColor(color)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius,
                               cornerHeight: radius, transform: nil))
        context.fillPath()
    }

    /// Middle-truncated rather than tail-truncated: what identifies a path is
    /// its last component, and a card that shows `/Volumes/DAILIES_SSD…` and
    /// stops has told the reader nothing.
    private func fitted(_ string: String, _ style: CardTextStyle,
                        maxWidth: CGFloat) -> String {
        guard width(of: string, style) > maxWidth else { return string }
        let characters = Array(string)
        var keep = characters.count
        while keep > 8 {
            keep -= 4
            let candidate = String(characters.prefix(keep / 2)) + "…"
                + String(characters.suffix(keep - keep / 2))
            if width(of: candidate, style) <= maxWidth { return candidate }
        }
        return "…"
    }

    private func width(of string: String, _ style: CardTextStyle) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line(string, style), nil, nil, nil))
    }

    private func line(_ string: String, _ style: CardTextStyle) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key: style.font,
            kCTForegroundColorAttributeName as NSAttributedString.Key:
                style.color,
        ]
        return CTLineCreateWithAttributedString(
            NSAttributedString(string: string, attributes: attributes))
    }
}
