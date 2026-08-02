import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The offload report as a PICTURE: one card per destination, drawn in the app's
/// own visual language, written beside the .txt summary and meant to be handed
/// over as-is.
///
/// **Why an image at all.** The .txt is the greppable record and the MHL is the
/// machine's receipt, but what actually gets asked for on a shooting day is
/// "send me a screenshot that the card is copied", and what gets sent back is a
/// phone photo of a laptop screen. This is that screenshot, made properly.
///
/// **Why PNG and not a single-page PDF.** Both were on the table:
///
/// - a PNG previews INLINE in every place a DIT actually sends it — Telegram,
///   WhatsApp, Slack, Mail — while a PDF arrives as an attachment somebody has
///   to decide to open, which on set means it is not read;
/// - the report is one screen by nature. It has a fixed set of fields and a
///   capped problem list, so pagination — the whole of the shift report's
///   `ReportPage` machinery — buys nothing here;
/// - the vector-text argument for PDF (searchable, selectable) is already
///   covered by the .txt written next to it, which is better at that job than a
///   PDF is.
///
/// So the shift-report machinery is deliberately NOT reused: it is a paginated
/// A4 take table, private to its own file, and built on AppKit in TakeShotKit.
/// Reusing it would mean dragging AppKit into CaptureCore or moving the offload
/// report out of the engine that knows when a run finished. What IS shared is
/// the approach — a small drawing class over a CGContext with a y cursor
/// counted from the top of the page (see `OffloadReportCanvas`).
///
/// Labels are injected in the app's language, defaulting to English, exactly
/// like the .txt beside it (see `OffloadReportLabels`) — the two are renderings
/// of one report and must speak one language.
public enum OffloadReportCard {
    /// Point width of the card. Wide enough for a destination path at 13pt
    /// without truncation on any sane volume layout.
    public static let width: CGFloat = 900

    /// Drawn at 2x, like a Retina screenshot. The card is looked at on a phone
    /// as often as on a monitor, and 1x text on a phone is mush.
    public static let scale: CGFloat = 2

    /// Same stem as the .txt summary, so the pair sorts together in the Finder
    /// and `OffloadVerify.isReportFile` recognizes both by one rule.
    public static let fileExtension = "png"

    /// Write the card into `destination`, returning its URL.
    @discardableResult
    public static func write(result: OffloadDestinationResult,
                             run: OffloadRunFacts,
                             into destination: URL, date: Date,
                             labels: OffloadReportLabels = .english) throws -> URL {
        let name = "\(OffloadSummary.filePrefix)"
            + "\(OffloadFormat.fileStamp(date)).\(fileExtension)"
        let url = CapturePipeline.uniqueURL(
            for: destination.appendingPathComponent(name))
        defer { CapturePipeline.releaseReservation(for: url) }
        guard let data = png(result: result, run: run, labels: labels) else {
            throw OffloadError.cannotRenderReport
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    /// The card as PNG bytes. nil only if CoreGraphics refused a context, which
    /// on this path means the process is out of memory.
    public static func png(result: OffloadDestinationResult,
                           run: OffloadRunFacts,
                           labels: OffloadReportLabels = .english) -> Data? {
        let problems = shown(problems(result: result, run: run, labels: labels),
                             labels: labels)
        let height = CardMetrics.height(problemLines: problems.count)
        guard let context = makeContext(height: height) else { return nil }
        OffloadReportCanvas(context: context, height: height, labels: labels)
            .draw(result: result, run: run, problems: problems)
        guard let image = context.makeImage() else { return nil }
        return encodePNG(image)
    }

    // MARK: - what went wrong, in reading order

    /// Worst first, the same precedence the .txt verdict uses: a dead
    /// destination, then files that did not match, then what the card would not
    /// give up at all.
    static func problems(result: OffloadDestinationResult,
                         run: OffloadRunFacts,
                         labels: OffloadReportLabels = .english) -> [String] {
        var lines: [String] = []
        if let failure = result.failure {
            lines.append(String(format: labels.destinationFailedLineFormat,
                                failure))
        }
        lines += result.mismatches
        lines += run.problems.source
        lines += run.problems.scan
        return lines
    }

    /// A disk that lost a folder produces hundreds of lines, and a card that is
    /// four screens tall is one nobody scrolls to the verdict on. The count is
    /// the fact, the first few names are the lead, and the .txt beside it has
    /// the rest — the same rule the verify sheet's lists follow.
    static func shown(_ all: [String],
                      labels: OffloadReportLabels = .english) -> [String] {
        guard all.count > CardMetrics.maxProblemLines else { return all }
        return Array(all.prefix(CardMetrics.maxProblemLines))
            + [String(format: labels.moreProblemsFormat,
                      all.count - CardMetrics.maxProblemLines)]
    }

    /// Where the machine's checksum list is, relative to the copy — or that it
    /// is not there, which the card has to state rather than leave blank.
    ///
    /// Named as the checksum list and never as "the receipt" (owner item 24).
    /// The receipt is THIS card and the .txt beside it, both in the root of the
    /// copy; the `ascmhl/` path below is the machine's file, and a footer that
    /// called it the receipt read as though the thing the operator was handed
    /// had been filed away in a subfolder.
    static func checksumList(_ result: OffloadDestinationResult,
                             labels: OffloadReportLabels = .english) -> String {
        guard let manifest = result.manifestURL else {
            return labels.checksumListMissing
        }
        return OffloadEngine.relativePath(of: manifest, under: result.url)
    }

    // MARK: - the bitmap

    private static func makeContext(height: CGFloat) -> CGContext? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: Int(width * scale),
                height: Int(height * scale), bitsPerComponent: 8,
                bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        // Everything below draws in points and never learns about the scale.
        context.scaleBy(x: scale, y: scale)
        return context
    }

    private static func encodePNG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
