import CoreGraphics
import CoreText
import Foundation

/// The burn-in compositor for one clip: white text on semi-transparent dark
/// strips, so the lines read on any picture — a blown-out sky and a night
/// exterior alike.
///
/// The layout is the classic dailies arrangement: timecode top-center, clip
/// name bottom-left, project (and date) bottom-right, the custom line top-left.
///
/// Built ONCE per clip. The three static strips are rendered here, at init,
/// into small CGImages and blitted per frame; only the timecode's text changes
/// frame to frame, so only that strip is re-drawn — one rect fill and one
/// `CTLine` per frame, with the font and attributes cached. CoreText rather
/// than AppKit, like `OffloadReportCanvas` and for the same reason: CaptureCore
/// has no AppKit dependency and is not going to grow one for a text strip.
public final class DailiesOverlay {
    /// The strip texts, resolved from the toggles. nil — that strip is off.
    public struct Texts: Sendable, Equatable {
        /// Top-left free line.
        public var custom: String?
        /// Bottom-left clip/take name.
        public var clipName: String?
        /// Bottom-right project line (already composed with the date).
        public var project: String?
        /// Widest text the TC strip must hold ("00:00:00:00"); nil — TC off.
        /// A template rather than a live value so the plate never resizes as
        /// the digits run.
        public var timecodeTemplate: String?

        public init(custom: String? = nil, clipName: String? = nil,
                    project: String? = nil, timecodeTemplate: String? = nil) {
            self.custom = custom
            self.clipName = clipName
            self.project = project
            self.timecodeTemplate = timecodeTemplate
        }
    }

    /// Where each strip lands, in top-left-origin IMAGE coordinates — the
    /// space the tests sample decoded frames in. nil — the strip is off.
    public struct Layout: Sendable, Equatable {
        public var timecode: CGRect?
        public var clipName: CGRect?
        public var project: CGRect?
        public var custom: CGRect?
    }

    /// One pre-rendered strip and where it goes (CG bottom-left coordinates).
    private struct Strip {
        var image: CGImage
        var rect: CGRect
    }

    public let layout: Layout
    private let size: CGSize
    private let metrics: DailiesStripMetrics
    private var staticStrips: [Strip] = []
    /// The one strip whose text runs: plate rect (CG coordinates), the cached
    /// font and the cached attributes the per-frame `CTLine` is built with.
    private let timecodePlate: CGRect?
    private let timecodeFont: CTFont
    private let textAttributes: [NSAttributedString.Key: Any]

    public init(size: CGSize, texts: Texts) {
        self.size = size
        let metrics = DailiesStripMetrics(height: size.height)
        self.metrics = metrics
        self.timecodeFont = metrics.timecodeFont

        var layout = Layout()
        let bodyFont = metrics.bodyFont
        if let custom = texts.custom {
            layout.custom = metrics.strip(
                for: custom, font: bodyFont, in: size, corner: .topLeft)
        }
        if let name = texts.clipName {
            layout.clipName = metrics.strip(
                for: name, font: bodyFont, in: size, corner: .bottomLeft)
        }
        if let project = texts.project {
            layout.project = metrics.strip(
                for: project, font: bodyFont, in: size, corner: .bottomRight)
        }
        if let template = texts.timecodeTemplate {
            layout.timecode = metrics.strip(
                for: template, font: metrics.timecodeFont, in: size,
                corner: .topCenter)
        }
        self.layout = layout
        self.timecodePlate = layout.timecode.map { Self.flip($0, in: size) }
        self.textAttributes = [
            kCTFontAttributeName as NSAttributedString.Key: metrics.timecodeFont,
            kCTForegroundColorAttributeName as NSAttributedString.Key:
                DailiesStripMetrics.textColor,
        ]

        for (rect, text) in [(layout.custom, texts.custom),
                             (layout.clipName, texts.clipName),
                             (layout.project, texts.project)] {
            guard let rect, let text,
                  let image = renderStrip(text: text, font: bodyFont,
                                          size: rect.size) else { continue }
            staticStrips.append(Strip(image: image,
                                      rect: Self.flip(rect, in: size)))
        }
    }

    /// Composite every enabled strip into `context` (a CG context wrapping the
    /// output frame, bottom-left origin). Called once per frame.
    public func draw(in context: CGContext, timecodeText: String?) {
        for strip in staticStrips {
            context.draw(strip.image, in: strip.rect)
        }
        guard let plate = timecodePlate, let timecodeText else { return }
        context.setFillColor(DailiesStripMetrics.plateColor)
        context.fill(plate)
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: timecodeText, attributes: textAttributes))
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent,
                                                       &descent, nil))
        context.textPosition = CGPoint(
            // Centered on the fixed plate: the digits are monospaced, so the
            // text never walks as they run.
            x: plate.midX - width / 2,
            y: plate.midY - (ascent - descent) / 2)
        CTLineDraw(line, context)
    }

    /// One static strip as a bitmap: the plate and its text, rendered once.
    private func renderStrip(text: String, font: CTFont,
                             size: CGSize) -> CGImage? {
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())
        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)
                      ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(DailiesStripMetrics.plateColor)
        context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: text, attributes: [
                kCTFontAttributeName as NSAttributedString.Key: font,
                kCTForegroundColorAttributeName as NSAttributedString.Key:
                    DailiesStripMetrics.textColor,
            ]))
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        context.textPosition = CGPoint(
            x: metrics.textInset,
            y: size.height / 2 - (ascent - descent) / 2)
        CTLineDraw(line, context)
        return context.makeImage()
    }

    /// Image coordinates (origin top-left, the space frames are sampled in) →
    /// CG coordinates (origin bottom-left, the space frames are drawn in).
    /// Converted once at init rather than at every draw.
    private static func flip(_ rect: CGRect, in size: CGSize) -> CGRect {
        CGRect(x: rect.minX, y: size.height - rect.maxY,
               width: rect.width, height: rect.height)
    }
}

/// The measurements every strip shares, derived from the output height so a
/// 720p daily and a 1080p daily read the same on the same monitor.
struct DailiesStripMetrics {
    enum Corner {
        case topLeft, topCenter, bottomLeft, bottomRight
    }

    /// Dark enough to hold white text over a blown-out window, transparent
    /// enough that the picture stays readable behind it.
    static let plateColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.55)
    static let textColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

    /// Strip height, text size and margins as fractions of the frame height.
    let stripHeight: CGFloat
    let margin: CGFloat
    let textInset: CGFloat

    init(height: CGFloat) {
        stripHeight = max(14, (height * 0.05).rounded())
        margin = (height * 0.04).rounded()
        textInset = (stripHeight * 0.45).rounded()
    }

    var bodyFont: CTFont {
        CTFontCreateUIFontForLanguage(.system, stripHeight * 0.58, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString,
                                    stripHeight * 0.58, nil)
    }

    /// Fixed-pitch for the timecode, so running digits do not shimmer.
    var timecodeFont: CTFont {
        CTFontCreateUIFontForLanguage(.userFixedPitch, stripHeight * 0.58, nil)
            ?? CTFontCreateWithName("Menlo" as CFString,
                                    stripHeight * 0.58, nil)
    }

    /// The strip rect for one text, in top-left-origin image coordinates:
    /// text width plus insets, clamped to the frame's writable width.
    func strip(for text: String, font: CTFont, in size: CGSize,
               corner: Corner) -> CGRect {
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: text.isEmpty ? " " : text,
            attributes: [kCTFontAttributeName as NSAttributedString.Key: font]))
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let width = min(size.width - 2 * margin,
                        (textWidth + 2 * textInset).rounded())
        let x: CGFloat
        switch corner {
        case .topLeft, .bottomLeft:
            x = margin
        case .topCenter:
            x = ((size.width - width) / 2).rounded()
        case .bottomRight:
            x = size.width - margin - width
        }
        let y: CGFloat
        switch corner {
        case .topLeft, .topCenter:
            y = margin
        case .bottomLeft, .bottomRight:
            y = size.height - margin - stripHeight
        }
        return CGRect(x: x, y: y, width: width, height: stripHeight)
    }
}

public extension DailiesBurnins {
    /// The toggles applied to one item's facts: what each strip actually says.
    /// Project and date share the bottom-right strip (four corners, five
    /// facts), joined with the separator the take log already uses.
    func overlayTexts(for item: DailiesItem) -> DailiesOverlay.Texts {
        var bottomRight: [String] = []
        if project, !item.projectLine.isEmpty {
            bottomRight.append(item.projectLine)
        }
        if date, !item.dateText.isEmpty {
            bottomRight.append(item.dateText)
        }
        return DailiesOverlay.Texts(
            custom: customText.isEmpty ? nil : customText,
            clipName: clipName ? item.clipName : nil,
            project: bottomRight.isEmpty ? nil
                : bottomRight.joined(separator: " · "),
            timecodeTemplate: timecode ? "00:00:00:00" : nil)
    }
}
