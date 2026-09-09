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
        /// Bottom-right project line.
        public var project: String?
        /// Recording date. Its OWN strip since the positions became the
        /// operator's: it used to be joined onto the project line with " · "
        /// because four corners could not hold five facts, and that stopped
        /// being the constraint the moment every line got a place of its own —
        /// leaving the date as the one fact that could not be moved and no way
        /// to say why (owner: "не оч понятно почему у рекординг дейт нельзя
        /// выбрать положение").
        public var date: String?
        /// Widest text the TC strip must hold ("00:00:00:00"); nil — TC off.
        /// A template rather than a live value so the plate never resizes as
        /// the digits run.
        public var timecodeTemplate: String?

        /// Where each line sits. Defaults are the classic dailies
        /// arrangement, which is what every existing caller means.
        public var customPosition: DailiesBurninPosition = .topLeft
        public var clipNamePosition: DailiesBurninPosition = .bottomLeft
        public var projectPosition: DailiesBurninPosition = .bottomRight
        public var timecodePosition: DailiesBurninPosition = .topCenter
        /// Bottom-right by default, which is where the date has always been
        /// drawn — stacked under the project line when both are on, by the
        /// same rule any two strips in one corner follow.
        public var datePosition: DailiesBurninPosition = .bottomRight

        /// How solid the TECHNICAL lines are — the timecode, the clip name,
        /// the project, the date. One ink for the four of them: they are the
        /// same kind of thing and four separate dials would be a panel nobody
        /// finishes reading.
        public var ink: DailiesInk = .standard
        /// …and the custom line's own, because it is the one that gets pointed
        /// at the middle of the frame and used as a watermark.
        public var customInk: DailiesInk = .standard

        public init(custom: String? = nil, clipName: String? = nil,
                    project: String? = nil, timecodeTemplate: String? = nil,
                    date: String? = nil,
                    customPosition: DailiesBurninPosition = .topLeft,
                    clipNamePosition: DailiesBurninPosition = .bottomLeft,
                    projectPosition: DailiesBurninPosition = .bottomRight,
                    timecodePosition: DailiesBurninPosition = .topCenter,
                    datePosition: DailiesBurninPosition = .bottomRight,
                    ink: DailiesInk = .standard,
                    customInk: DailiesInk = .standard) {
            self.custom = custom
            self.clipName = clipName
            self.project = project
            self.timecodeTemplate = timecodeTemplate
            self.customPosition = customPosition
            self.clipNamePosition = clipNamePosition
            self.projectPosition = projectPosition
            self.timecodePosition = timecodePosition
            self.date = date
            self.datePosition = datePosition
            self.ink = ink
            self.customInk = customInk
        }
    }

    /// Where each strip lands, in top-left-origin IMAGE coordinates — the
    /// space the tests sample decoded frames in. nil — the strip is off.
    public struct Layout: Sendable, Equatable {
        public var timecode: CGRect?
        public var clipName: CGRect?
        public var project: CGRect?
        public var custom: CGRect?
        public var date: CGRect?
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
    /// The running timecode's plate, held because it is re-filled every frame.
    private let plateColor: CGColor

    /// Where the five strips land.
    ///
    /// **Stacked when two lines want the same place.** The positions are the
    /// operator's, and nothing stops them putting the clip name and the
    /// project in the same corner — which used to be impossible and is now one
    /// picker away. Strips at one position step INWARD from their edge, in the
    /// order below, so the arrangement is the same every run and no line is
    /// ever hidden under another.
    ///
    /// The date is placed LAST, so project and date sharing bottom-right come
    /// out in the order they were joined in when the date had no place of its
    /// own.
    ///
    /// Its own function rather than part of `init` because the fifth strip
    /// took the initializer past the body-length rule — and because "where
    /// does each line go" is one question, answerable without a whole overlay.
    private static func arrange(_ texts: Texts,
                                metrics: DailiesStripMetrics,
                                in size: CGSize) -> Layout {
        var layout = Layout()
        let bodyFont = metrics.bodyFont
        var used: [DailiesBurninPosition: Int] = [:]
        func place(_ text: String, font: CTFont,
                   at position: DailiesBurninPosition) -> CGRect {
            let index = used[position, default: 0]
            used[position] = index + 1
            var rect = metrics.strip(for: text, font: font, in: size,
                                     corner: position)
            let step = (metrics.stripHeight + metrics.stripHeight * 0.25).rounded()
            // A middle strip steps the way a top one does, so two lines
            // pointed at the centre read downward in the order below rather
            // than growing out of the frame's waist in both directions.
            rect.origin.y += position.isTop || position.isMiddle
                ? step * CGFloat(index) : -step * CGFloat(index)
            return rect
        }
        if let template = texts.timecodeTemplate {
            layout.timecode = place(template, font: metrics.timecodeFont,
                                    at: texts.timecodePosition)
        }
        if let custom = texts.custom {
            layout.custom = place(custom, font: bodyFont,
                                  at: texts.customPosition)
        }
        if let name = texts.clipName {
            layout.clipName = place(name, font: bodyFont,
                                    at: texts.clipNamePosition)
        }
        if let project = texts.project {
            layout.project = place(project, font: bodyFont,
                                   at: texts.projectPosition)
        }
        if let date = texts.date {
            layout.date = place(date, font: bodyFont, at: texts.datePosition)
        }
        return layout
    }

    public init(size: CGSize, texts: Texts) {
        self.size = size
        let metrics = DailiesStripMetrics(height: size.height)
        self.metrics = metrics
        self.timecodeFont = metrics.timecodeFont

        let bodyFont = metrics.bodyFont
        let layout = Self.arrange(texts, metrics: metrics, in: size)
        self.layout = layout
        self.timecodePlate = layout.timecode.map { Self.flip($0, in: size) }
        self.plateColor = texts.ink.plateColor
        self.textAttributes = [
            kCTFontAttributeName as NSAttributedString.Key: metrics.timecodeFont,
            kCTForegroundColorAttributeName as NSAttributedString.Key:
                texts.ink.textColor,
        ]

        for (rect, text, ink) in [
            (layout.custom, texts.custom, texts.customInk),
            (layout.clipName, texts.clipName, texts.ink),
            (layout.project, texts.project, texts.ink),
            (layout.date, texts.date, texts.ink),
        ] {
            guard let rect, let text,
                  let image = renderStrip(text: text, font: bodyFont,
                                          size: rect.size,
                                          ink: ink) else { continue }
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
        context.setFillColor(plateColor)
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

    /// **The burn-ins as a picture — the same code that burns the frame.**
    ///
    /// What the operator asked to see before committing a batch (owner: "а
    /// главное визуализации"). Worth saying why this is a rendering rather than
    /// a mock-up of the layout in SwiftUI: a preview drawn by different code is
    /// a preview that can be WRONG, and the one question it exists to answer is
    /// whether the real thing will look like this. So it goes through the same
    /// `init` and the same `draw`, at a smaller size — the metrics are
    /// fractions of the frame height, so a small frame gives proportionally
    /// smaller strips, which is what a preview is.
    ///
    /// `timecodeText` is a sample: the plate is sized from the template, so
    /// what an operator needs to see is where the digits sit, not which.
    /// `backgroundImage` is a real frame from the footage when there is one:
    /// a plate's opacity and a watermark's lettering cannot be judged against
    /// flat grey (owner: "хотелось бы чтобы картинкой встал как пример какой-то
    /// один стилл из любого исходника… вместо серого фона"). Drawn to FILL the
    /// preview, so a source of any aspect covers it rather than leaving bars
    /// the strips would then be measured against.
    public static func previewImage(size: CGSize, texts: Texts,
                                    background: CGColor,
                                    backgroundImage: CGImage? = nil,
                                    timecodeText: String = "01:23:45:12")
        -> CGImage? {
        let width = max(1, Int(size.width.rounded()))
        let height = max(1, Int(size.height.rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)
                ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        let frame = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(background)
        context.fill(frame)
        if let backgroundImage {
            context.draw(backgroundImage, in: Self.fill(frame,
                                                        with: backgroundImage))
        }
        DailiesOverlay(size: CGSize(width: width, height: height), texts: texts)
            .draw(in: context, timecodeText: timecodeText)
        return context.makeImage()
    }

    /// The rect to draw `image` into so it COVERS `frame` — the aspect is
    /// kept and the overflow is cropped, which is what a preview background
    /// wants: letterbox bars are not part of the picture the strips will sit
    /// on, and judging a plate against them would be judging it against grey.
    static func fill(_ frame: CGRect, with image: CGImage) -> CGRect {
        let source = CGSize(width: image.width, height: image.height)
        guard source.width > 0, source.height > 0 else { return frame }
        let scale = max(frame.width / source.width,
                        frame.height / source.height)
        let size = CGSize(width: source.width * scale,
                          height: source.height * scale)
        return CGRect(x: frame.midX - size.width / 2,
                      y: frame.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// One static strip as a bitmap: the plate and its text, rendered once.
    private func renderStrip(text: String, font: CTFont, size: CGSize,
                             ink: DailiesInk) -> CGImage? {
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
        context.setFillColor(ink.plateColor)
        context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: text, attributes: [
                kCTFontAttributeName as NSAttributedString.Key: font,
                kCTForegroundColorAttributeName as NSAttributedString.Key:
                    ink.textColor,
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
/// Where one burn-in line sits on the frame.
///
/// **Six places, and they are the operator's to choose.** The layout used to be
/// fixed — timecode top-centre, clip name bottom-left, project bottom-right,
/// the free line top-left — which is the classic arrangement and is right until
/// it is not: a camera that burns its own timecode into the top of the frame,
/// a slate in one corner, a client who wants the reel where they are used to
/// reading it (owner: "в дейлизах хочется при настройке оверлеев какой-то
/// большей кастомизации положения и настроек").
///
/// A raw-valued enum because these are persisted, and the raw values are the
/// stored keys — see `DailiesSettings`.
/// **How solid one burn-in is** — its plate and its lettering, separately.
///
/// Two numbers rather than one because they answer different questions: the
/// plate is how much of the picture the strip hides, and the text is how much
/// of the strip you can read. A watermark across the middle of the frame wants
/// almost no plate and half the lettering; a timecode on the top edge wants a
/// plate dark enough to hold white text over a blown sky (owner: "хотелось бы
/// еще иметь возможность настроить опасити подложки и опасити самого текста
/// там отдельно для технических штук и отдельно для кастом тайтла").
///
/// The defaults are what every daily this app has burned so far.
public struct DailiesInk: Sendable, Equatable {
    /// 0 — no plate at all, the text straight onto the picture.
    public var plate: Double
    /// 0 — invisible; 1 — solid white.
    public var text: Double

    /// Dark enough to hold white text over a blown-out window, transparent
    /// enough that the picture stays readable behind it.
    public static let standard = DailiesInk(plate: 0.55, text: 1)

    public init(plate: Double = 0.55, text: Double = 1) {
        self.plate = plate
        self.text = text
    }

    /// **Both dials inside 0…1.**
    ///
    /// These arrive from a settings blob a hand can edit. `CGColor` happens to
    /// clamp an out-of-range alpha itself, which is exactly why this is a
    /// property and not a `min/max` buried in the two colours below: clamping
    /// that nothing can observe is clamping no test can hold, and the first
    /// version of it was removable without a single failure.
    public var clamped: DailiesInk {
        DailiesInk(plate: min(1, max(0, plate)), text: min(1, max(0, text)))
    }

    public var plateColor: CGColor {
        CGColor(srgbRed: 0, green: 0, blue: 0, alpha: clamped.plate)
    }

    public var textColor: CGColor {
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: clamped.text)
    }
}

public enum DailiesBurninPosition: String, CaseIterable, Sendable, Codable {
    case topLeft, topCenter, topRight
    /// **The middle of the frame**, which is what a watermark wants (owner:
    /// "давай еще добавим centre прям. ну допустим чтобы кастом тайтл можно
    /// было использовать как вотермарку"). The only position that is over the
    /// picture rather than along an edge, and the reason the opacity of the
    /// plate and the text became settings.
    case center
    case bottomLeft, bottomCenter, bottomRight

    /// Whether this sits along the top edge — the half of the answer that
    /// decides the y, and the half two positions in the same corner share.
    public var isTop: Bool {
        self == .topLeft || self == .topCenter || self == .topRight
    }

    /// The middle of the frame: neither edge, and the x is centred like the
    /// two other centre positions.
    public var isMiddle: Bool { self == .center }
}

public struct DailiesStripMetrics {
    typealias Corner = DailiesBurninPosition

    /// Dark enough to hold white text over a blown-out window, transparent
    /// enough that the picture stays readable behind it.
    /// The standard ink's two colours, kept here because callers outside the
    /// overlay read them (the preview's background, the tests) — the strips
    /// themselves take their colours from a `DailiesInk` now, one per group.
    static let plateColor = DailiesInk.standard.plateColor
    static let textColor = DailiesInk.standard.textColor

    /// Below this a strip is a line nobody can read, whatever the raster —
    /// named because the dailies PREVIEW has to be rendered large enough that
    /// this floor does not bind, or it shows thicker plates than the daily
    /// will carry (`thePreviewRasterIsBigEnoughToShowTheRealStripHeight`).
    public static let minimumStripHeight: CGFloat = 14

    /// Strip height, text size and margins as fractions of the frame height.
    let stripHeight: CGFloat
    let margin: CGFloat
    let textInset: CGFloat

    init(height: CGFloat) {
        stripHeight = max(Self.minimumStripHeight, (height * 0.05).rounded())
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
        case .topCenter, .bottomCenter, .center:
            x = ((size.width - width) / 2).rounded()
        case .topRight, .bottomRight:
            x = size.width - margin - width
        }
        let y: CGFloat
        if corner.isMiddle {
            y = ((size.height - stripHeight) / 2).rounded()
        } else if corner.isTop {
            y = margin
        } else {
            y = size.height - margin - stripHeight
        }
        return CGRect(x: x, y: y, width: width, height: stripHeight)
    }
}

public extension DailiesBurnins {
    /// The toggles applied to one item's facts: what each strip actually says.
    ///
    /// Five strips, not four. The date used to be joined onto the project line
    /// because the layout had four corners and this set has five facts; every
    /// line carries its own position now, so the date carries one too and the
    /// stacking rule handles the pair when both are pointed at one corner —
    /// which is what they default to, so the classic arrangement is unchanged
    /// on screen while the date has become movable.
    func overlayTexts(for item: DailiesItem) -> DailiesOverlay.Texts {
        DailiesOverlay.Texts(
            custom: customText.isEmpty ? nil : customText,
            clipName: clipName ? item.clipName : nil,
            project: project && !item.projectLine.isEmpty
                ? item.projectLine : nil,
            timecodeTemplate: timecode ? "00:00:00:00" : nil,
            date: date && !item.dateText.isEmpty ? item.dateText : nil,
            customPosition: customPosition,
            clipNamePosition: clipNamePosition,
            projectPosition: projectPosition,
            timecodePosition: timecodePosition,
            datePosition: datePosition,
            ink: ink, customInk: customInk)
    }
}
