import CoreGraphics
import Foundation

/// Legend size. It is read from behind the camera, across the room, by someone
/// who is not wearing their glasses — one size does not fit every set, so the
/// operator picks.
///
/// The three cases moved here from the SwiftUI overlay they used to size (see
/// `AssistLegend` below for why the legend is drawn into the frame now). The
/// raw values are what `CaptureSettings.legendSize` persists, so renaming a
/// case silently resets the operator's choice.
public enum AssistLegendSize: String, CaseIterable, Identifiable, Sendable {
    case small = "s"
    case medium = "m"
    case large = "l"

    public var id: String { rawValue }

    /// Every dimension the legend is built from, in reference points — see
    /// `AssistLegendMetrics`.
    var metrics: AssistLegendMetrics {
        switch self {
        case .small:
            return AssistLegendMetrics(
                swatchThickness: 14, falseColorBand: 52, elZoneBand: 38,
                bandHeight: 18, bandWidth: 30, fontSize: 11,
                padding: 12, verticalPadding: 6, corner: 8, gap: 2, labelGap: 3)
        case .medium:
            return AssistLegendMetrics(
                swatchThickness: 19, falseColorBand: 70, elZoneBand: 50,
                bandHeight: 24, bandWidth: 40, fontSize: 15,
                padding: 16, verticalPadding: 8, corner: 10, gap: 2, labelGap: 4)
        case .large:
            return AssistLegendMetrics(
                swatchThickness: 26, falseColorBand: 92, elZoneBand: 66,
                bandHeight: 32, bandWidth: 54, fontSize: 20,
                padding: 20, verticalPadding: 10, corner: 12, gap: 3,
                labelGap: 5)
        }
    }
}

/// Which edge of the FRAME the legend sits against.
///
/// Edges and not corners (which is what this was): the legend is a strip of
/// bands, so the useful choice is which edge it runs along — down the left or
/// the right, or across the top or the bottom — and the strip turns to match.
/// A stored corner is carried over in `CaptureSettings.migrateToVersion3`.
public enum AssistLegendPlacement: String, CaseIterable, Identifiable, Sendable {
    case top
    case bottom
    case left
    case right

    public var id: String { rawValue }

    /// The default, stated once: bottom, centered.
    public static let standard = AssistLegendPlacement.bottom

    /// A left/right legend runs down the picture and its labels sit beside the
    /// swatches; a top/bottom one runs across it with the labels underneath.
    public var isVertical: Bool { self == .left || self == .right }
}

/// Every dimension the legend is built from, in REFERENCE POINTS: the sizes it
/// has on a 1080-tall frame. `AssistLegend.layout` multiplies the whole set by
/// one scale factor, so a UHD output gets a legend of the same apparent size
/// rather than a postage stamp, and a 720p one is not covered by it.
struct AssistLegendMetrics {
    /// Thickness of the swatch row in a horizontal strip.
    var swatchThickness: CGFloat
    /// Width of one band in a horizontal strip. False colour has 9 bands and
    /// EL Zone 13, so the wider strip gets the narrower band — neither may run
    /// off the side of the picture.
    var falseColorBand: CGFloat
    var elZoneBand: CGFloat
    /// Vertical strip: one band's height, and the width of its swatch. The band
    /// is sized off the label rather than off the horizontal swatch — thirteen
    /// EL Zone bands as tall as they are wide would be a strip longer than the
    /// frame is high.
    var bandHeight: CGFloat
    var bandWidth: CGFloat
    var fontSize: CGFloat
    var padding: CGFloat
    var verticalPadding: CGFloat
    var corner: CGFloat
    /// Between two bands, and between a swatch and its label.
    var gap: CGFloat
    var labelGap: CGFloat

    /// The line of text under (or beside) a swatch.
    var labelHeight: CGFloat { (fontSize * 1.25).rounded() }
    /// One label column for a whole vertical strip, so the swatches line up.
    /// Three digit-widths: the longest label either palette carries is "92-97"
    /// on the horizontal strip and "+6" on the vertical one.
    var labelWidth: CGFloat { fontSize * 3 }
}

/// The exposure legend — the key to what false colour and EL Zone are painting
/// — burned into the DISPLAY frame beside the guides.
///
/// It used to be a SwiftUI overlay on the player, on the reasoning that a key
/// to the picture is chrome rather than a mark on it. The owner overruled that:
/// an overlay lives on the surface it is mounted on, so the legend reached the
/// operator's window and nothing else — not the director's monitor, and above
/// all not the hardware playout, which is a pixel buffer with no view tree to
/// hang an overlay in. A colourist on the monitor being shown nine flat colours
/// with no key to them is the case that decided it.
///
/// So it is drawn where the guides are drawn (`AssistGuides`), at the SIGNAL's
/// resolution, in the shared display stage — which puts it on every mirror of
/// the viewer at once and, by construction, on no deliverable: the writer, the
/// grab and the scopes are all served before the display hop exists. The phone
/// camera grid is handed the clean frame and so never sees it either
/// (`CapturePipeline.publishDisplayFrame`). `AssistIntegrityTests` pixel-proves
/// all of that.
///
/// The cost of being part of the picture: the punch-in and the desqueeze are
/// per-surface geometry, so a magnified viewer crops the strip out of its own
/// viewport. That is the same bargain the framelines took, and the hardware
/// monitor — which is fed the whole frame — keeps the legend throughout.
public struct AssistLegend: Equatable, Sendable {
    /// The frame height every metric above is stated at.
    static let referenceHeight: CGFloat = 1080
    /// How far the strip stays off the edge of the picture, in reference
    /// points. There is no player chrome to clear any more — the legend is
    /// inside the frame now, and this is the margin that keeps it off the very
    /// edge of an overscanning monitor.
    static let margin: CGFloat = 24
    /// Below this the panel is a smudge rather than a legend, and CoreText
    /// draws sub-pixel glyphs as grey mush: the strip is skipped entirely.
    static let minimumPanel = CGSize(width: 12, height: 6)
    /// Labels are drawn only once they are this tall in real pixels. The
    /// swatches — which carry most of what the legend says — keep going below
    /// it, so a small signal still gets a colour key.
    static let minimumLabelSize: CGFloat = 5

    public var size: AssistLegendSize = .medium
    public var placement: AssistLegendPlacement = .standard

    public init(size: AssistLegendSize = .medium,
                placement: AssistLegendPlacement = .standard) {
        self.size = size
        self.placement = placement
    }

    /// The legend as the operator's settings describe it. One conversion, so
    /// the value the renderer draws and the value the popover edits cannot
    /// disagree about what "medium" or "bottom" means.
    public init(settings: CaptureSettings) {
        self.init(
            size: AssistLegendSize(rawValue: settings.legendSize ?? "") ?? .medium,
            placement: AssistLegendPlacement(
                rawValue: settings.legendPlacement ?? "") ?? .standard)
    }

    // MARK: - what the bands say

    /// One band of the legend: the colour the picture is painted with, and the
    /// exposure it stands for.
    struct Entry: Equatable {
        var color: AssistFilters.BandColor
        /// A stop mark, never a translated word: the strip is a scale, and
        /// "18%" or "+3" says the same thing in every language on the call
        /// sheet. The gray-ramp bands carry no label at all.
        var label: String
    }

    /// What false colour's nine bands are called. Paired with
    /// `AssistFilters.falseColorBands` by position — the colours themselves are
    /// read out of that table rather than restated here, so the swatch cannot
    /// drift from the paint (`AssistLegendTests` holds the two counts equal).
    static let falseColorLabels = ["<2", "2-8", "", "18%", "", "skin", "",
                                   "92-97", "clip"]

    /// The bands for a tool, darkest first.
    static func entries(for tool: ViewAssist.ColorTool) -> [Entry] {
        switch tool {
        case .off:
            return []
        case .falseColor:
            return falseColorEntries()
        case .elZone:
            return AssistFilters.elZoneRamp.enumerated().map { index, color in
                let stop = index - 6
                return Entry(color: color,
                             label: stop > 0 ? "+\(stop)" : "\(stop)")
            }
        }
    }

    /// Each false-colour band sampled at the MIDDLE of the range it covers, so
    /// a gray-ramp gap shows the gray the picture would actually be there
    /// instead of a colour invented for the legend.
    private static func falseColorEntries() -> [Entry] {
        var lower: Double = 0
        return AssistFilters.falseColorBands.enumerated().map { index, band in
            // the open top end stands for "clipped", i.e. full scale
            let upper = band.upTo.isFinite ? band.upTo : 1
            let color = AssistFilters.band((lower + upper) / 2)
            lower = upper
            let label = index < falseColorLabels.count
                ? falseColorLabels[index] : ""
            return Entry(color: color, label: label)
        }
    }

    // MARK: - where the strip lands

    /// The strip's box in the frame, and how big everything in it is.
    struct Layout: Equatable {
        /// The panel in the frame's own pixels, y UP — CoreImage's space, the
        /// one the display stage composites in.
        var rect: CGRect
        /// Reference points → frame pixels.
        var scale: CGFloat
        /// Whether the labels are legible at this scale (see
        /// `minimumLabelSize`).
        var showsLabels: Bool
    }

    /// Where the legend for `tool` goes on a frame of `size`, or nil when there
    /// is nothing to draw or no room to draw it in.
    ///
    /// The scale is the frame's height against the 1080 the metrics are stated
    /// at, then held down to whatever actually fits the frame — a 13-band
    /// EL Zone strip on a narrow signal shrinks rather than running off the
    /// side of the picture.
    func layout(for tool: ViewAssist.ColorTool, in size: CGSize) -> Layout? {
        let count = Self.entries(for: tool).count
        guard count > 0, size.width > 0, size.height > 0 else { return nil }
        let panel = panelSize(bands: count, tool: tool)
        let margin = Self.margin
        let scale = min(size.height / Self.referenceHeight,
                        size.width / (panel.width + 2 * margin),
                        size.height / (panel.height + 2 * margin))
        guard scale > 0 else { return nil }
        let width = (panel.width * scale).rounded()
        let height = (panel.height * scale).rounded()
        guard width >= Self.minimumPanel.width,
              height >= Self.minimumPanel.height else { return nil }
        let inset = (margin * scale).rounded()
        let rect = CGRect(origin: origin(panel: CGSize(width: width,
                                                       height: height),
                                         inset: inset, frame: size),
                          size: CGSize(width: width, height: height))
        return Layout(rect: rect, scale: scale,
                      showsLabels: self.size.metrics.fontSize * scale
                          >= Self.minimumLabelSize)
    }

    /// The panel at scale 1, in reference points.
    private func panelSize(bands: Int, tool: ViewAssist.ColorTool) -> CGSize {
        let metrics = size.metrics
        let count = CGFloat(bands)
        let gaps = (count - 1) * metrics.gap
        if placement.isVertical {
            return CGSize(
                width: metrics.bandWidth + metrics.labelGap + metrics.labelWidth
                    + 2 * metrics.padding,
                height: count * metrics.bandHeight + gaps
                    + 2 * metrics.verticalPadding)
        }
        let band = tool == .elZone ? metrics.elZoneBand : metrics.falseColorBand
        return CGSize(
            width: count * band + gaps + 2 * metrics.padding,
            height: metrics.swatchThickness + metrics.labelGap
                + metrics.labelHeight + 2 * metrics.verticalPadding)
    }

    /// The panel's bottom-left corner against the chosen edge, centered on the
    /// other axis.
    private func origin(panel: CGSize, inset: CGFloat,
                        frame: CGSize) -> CGPoint {
        let centerX = ((frame.width - panel.width) / 2).rounded()
        let centerY = ((frame.height - panel.height) / 2).rounded()
        switch placement {
        case .bottom:
            return CGPoint(x: centerX, y: inset)
        case .top:
            return CGPoint(x: centerX, y: frame.height - inset - panel.height)
        case .left:
            return CGPoint(x: inset, y: centerY)
        case .right:
            return CGPoint(x: frame.width - inset - panel.width, y: centerY)
        }
    }
}
