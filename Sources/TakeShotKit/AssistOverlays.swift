import CaptureCore
import SwiftUI

// What the operator aids draw ON TOP of the picture: the exposure legend, the
// framelines and the safe-area guides.
//
// Split out of AssistMenu (which owns the popover that switches them on) —
// these three are what the fullscreen windows and the main player share, and
// they are the ones that have to know where the chrome is and where the
// punched-in image has moved to.

// MARK: - legend size and placement

/// Legend size. It is read from behind the camera, across the room, by someone
/// who is not wearing their glasses — one size does not fit every set, so the
/// operator picks.
enum AssistLegendSize: String, CaseIterable, Identifiable {
    case small = "s"
    case medium = "m"
    case large = "l"

    var id: String { rawValue }
    var labelKey: String {
        switch self {
        case .small: return "legend_size_s"
        case .medium: return "legend_size_m"
        case .large: return "legend_size_l"
        }
    }

    /// Every dimension the legend is built from, at this size. `small` is the
    /// size the legend used to be at, fixed — the complaint was that it is
    /// tiny, so `medium` (the default) is bigger than what shipped.
    var metrics: AssistLegendMetrics {
        switch self {
        case .small:
            return AssistLegendMetrics(swatchHeight: 8, falseColorWidth: 30,
                                       elZoneWidth: 22, fontSize: 7,
                                       bandHeight: 11, bandWidth: 18,
                                       horizontalPadding: 8, verticalPadding: 4,
                                       cornerRadius: 6)
        case .medium:
            return AssistLegendMetrics(swatchHeight: 11, falseColorWidth: 40,
                                       elZoneWidth: 29, fontSize: 9,
                                       bandHeight: 13, bandWidth: 24,
                                       horizontalPadding: 10, verticalPadding: 5,
                                       cornerRadius: 7)
        case .large:
            return AssistLegendMetrics(swatchHeight: 15, falseColorWidth: 52,
                                       elZoneWidth: 38, fontSize: 12,
                                       bandHeight: 17, bandWidth: 32,
                                       horizontalPadding: 12, verticalPadding: 6,
                                       cornerRadius: 8)
        }
    }
}

struct AssistLegendMetrics {
    var swatchHeight: CGFloat
    /// False color has 9 bands, EL Zone 13 — the wider strip gets the narrower
    /// swatch so neither runs off the side of the player.
    var falseColorWidth: CGFloat
    var elZoneWidth: CGFloat
    var fontSize: CGFloat
    /// Vertical legend: one band's height, and the width of its swatch. The
    /// band is sized off the label rather than off the horizontal swatch —
    /// thirteen EL Zone bands as tall as they are wide would be a strip longer
    /// than the player is high.
    var bandHeight: CGFloat
    var bandWidth: CGFloat
    var horizontalPadding: CGFloat
    var verticalPadding: CGFloat
    var cornerRadius: CGFloat
}

/// Which edge of the player the legend sits against.
///
/// Edges and not corners (which is what this was): the legend is a strip of
/// bands, so the useful choice is which edge it runs along — down the left or
/// the right, or across the top or the bottom — and the strip turns to match.
/// A stored corner is carried over in `CaptureSettings.migrateToVersion3`.
enum AssistLegendPlacement: String, CaseIterable, Identifiable {
    case top
    case bottom
    case left
    case right

    var id: String { rawValue }

    /// The default, stated once: bottom, centered.
    static let standard = AssistLegendPlacement.bottom

    /// A left/right legend runs down the player and its labels sit beside the
    /// swatches; a top/bottom one runs across it with the labels underneath.
    var isVertical: Bool { self == .left || self == .right }

    var alignment: Alignment {
        switch self {
        case .top: return .top
        case .bottom: return .bottom
        case .left: return .leading
        case .right: return .trailing
        }
    }

    var labelKey: String {
        switch self {
        case .top: return "legend_top"
        case .bottom: return "legend_bottom"
        case .left: return "legend_left"
        case .right: return "legend_right"
        }
    }
}

/// How far the legend stays off each edge of the player.
///
/// The player's own chrome is what these numbers are made of. In fullscreen the
/// footer and the transport auto-hide, but they come back in the same place the
/// moment the pointer goes near them — a legend tucked into the bottom of the
/// screen there disappears under the controls exactly when the operator reaches
/// for them, which is what item 2 was about.
enum AssistLegendChrome {
    /// Clears the badge row over the image (8pt inset + the badge itself).
    static let topInset: CGFloat = 44
    /// Clears the transport bar the player floats at its bottom edge.
    static let bottomInset: CGFloat = 56
    /// Clears the fullscreen footer/transport band (the bar plus the 18pt it is
    /// lifted by). `ViewAssistToolsTests` measures the real bars against this.
    static let fullscreenBottomInset: CGFloat = 108
    static let sideInset: CGFloat = 12

    static func insets(placement: AssistLegendPlacement,
                       fullscreen: Bool) -> EdgeInsets {
        let bottom = fullscreen ? fullscreenBottomInset : bottomInset
        // A vertical legend is centered between the two bands of chrome, so it
        // carries BOTH insets: with only one of them a thirteen-band EL Zone
        // strip is centered on the player and runs under the transport.
        return EdgeInsets(
            top: placement == .bottom ? 0 : topInset,
            leading: sideInset,
            bottom: placement == .top ? 0 : bottom,
            trailing: sideInset)
    }
}

// MARK: - the legend itself

/// Color legend for the active exposure tool (false color / EL Zone).
struct AssistLegend: View {
    let tool: ViewAssist.ColorTool
    /// Defaulted: the size is an operator setting, and the callers that only
    /// care about the strip itself (the tests) should not have to state one.
    var size: AssistLegendSize = .medium
    /// Runs down the player rather than across it — what a left/right
    /// placement asks for.
    var vertical = false

    private var entries: [(Color, String)] {
        switch tool {
        case .falseColor:
            return [
                (Color(red: 0.58, green: 0.20, blue: 0.75), "<2"),
                (Color(red: 0.16, green: 0.34, blue: 0.90), "2-8"),
                (Color(white: 0.25), ""),
                (Color(red: 0.15, green: 0.75, blue: 0.25), "18%"),
                (Color(white: 0.55), ""),
                (Color(red: 0.95, green: 0.60, blue: 0.70), "skin"),
                (Color(white: 0.8), ""),
                (Color(red: 0.98, green: 0.90, blue: 0.20), "92-97"),
                (Color(red: 0.95, green: 0.15, blue: 0.10), "clip"),
            ]
        case .elZone:
            // the same stop palette the layer renders with (MetalPreviewLayer)
            return [
                (Color(red: 0.04, green: 0.04, blue: 0.04), "-6"),
                (Color(red: 0.45, green: 0.15, blue: 0.65), "-5"),
                (Color(red: 0.15, green: 0.25, blue: 0.90), "-4"),
                (Color(red: 0.10, green: 0.60, blue: 0.70), "-3"),
                (Color(red: 0.15, green: 0.65, blue: 0.25), "-2"),
                (Color(white: 0.32), "-1"),
                (Color(white: 0.50), "0"),
                (Color(white: 0.68), "+1"),
                (Color(red: 0.95, green: 0.60, blue: 0.65), "+2"),
                (Color(red: 0.95, green: 0.55, blue: 0.15), "+3"),
                (Color(red: 0.98, green: 0.72, blue: 0.30), "+4"),
                (Color(red: 0.98, green: 0.92, blue: 0.25), "+5"),
                (Color(white: 1), "+6"),
            ]
        case .off:
            return []
        }
    }

    var body: some View {
        Group {
            if vertical { verticalStrip } else { horizontalStrip }
        }
        .padding(.horizontal, size.metrics.horizontalPadding)
        .padding(.vertical, size.metrics.verticalPadding)
        .background(.black.opacity(0.65),
                    in: RoundedRectangle(cornerRadius: size.metrics.cornerRadius))
    }

    private var horizontalStrip: some View {
        let metrics = size.metrics
        let swatchWidth = tool == .elZone
            ? metrics.elZoneWidth : metrics.falseColorWidth
        return HStack(spacing: 1) {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                VStack(spacing: 2) {
                    Rectangle()
                        .fill(entry.0)
                        .frame(width: swatchWidth, height: metrics.swatchHeight)
                    Text(entry.1)
                        .font(.system(size: metrics.fontSize).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(height: metrics.fontSize + 1)
                }
            }
        }
    }

    /// The same bands stacked, labels alongside. Top band first, so the strip
    /// reads brightest-at-the-bottom exactly as the horizontal one reads
    /// brightest-at-the-right — the stops still run in one direction.
    private var verticalStrip: some View {
        let metrics = size.metrics
        // one label column for the whole strip, so the swatches line up
        let labelWidth = metrics.fontSize * 3
        return VStack(spacing: 1) {
            ForEach(Array(entries.enumerated().reversed()), id: \.offset) { _, entry in
                HStack(spacing: 3) {
                    Rectangle()
                        .fill(entry.0)
                        .frame(width: metrics.bandWidth, height: metrics.bandHeight)
                    Text(entry.1)
                        .font(.system(size: metrics.fontSize).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(width: labelWidth, alignment: .leading)
                }
            }
        }
    }
}

/// The legend against the edge the operator chose, clear of the chrome.
struct AssistLegendOverlay: View {
    @EnvironmentObject private var controller: CaptureController
    /// The fullscreen windows hide their chrome until the pointer asks for it.
    var fullscreen = false

    var body: some View {
        let tool = controller.assist.colorTool
        if tool != .off {
            let placement = controller.legendPlacement
            ZStack(alignment: placement.alignment) {
                Color.clear
                AssistLegend(tool: tool, size: controller.legendSize,
                             vertical: placement.isVertical)
                    .padding(AssistLegendChrome.insets(placement: placement,
                                                       fullscreen: fullscreen))
            }
            .allowsHitTesting(false)
        }
    }
}

// MARK: - framelines and safe areas

/// Framelines + safe areas over the picture, riding the punch-in transform.
///
/// The guides mark the SIGNAL's geometry: 2.39 is 2.39 of what the camera is
/// sending, so when the operator punches in they have to magnify and pan with
/// the image instead of staying pinned to the window (which is what they did —
/// the frameline sat still while the picture moved under it, and read as a
/// crop of the window). The transform comes from the same
/// `ViewAssist.placement` the renderer uses, so the two cannot drift apart.
struct AssistFramelines: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        let ratio = controller.settings.framelineRatio
        let safeAreas = controller.settings.safeAreasOn == true
        if ratio != nil || safeAreas {
            GeometryReader { geo in
                PlacedFramelines(
                    live: controller.assistLive,
                    viewport: geo.size,
                    sourceSize: controller.displaySourceSize(),
                    ratio: ratio,
                    safeAreas: safeAreas,
                    actionPercent: controller.settings.safeActionPercentEffective,
                    titlePercent: controller.settings.safeTitlePercentEffective)
            }
            // punched in, the guides reach past the player: clip them to it
            .clipped()
            .allowsHitTesting(false)
        }
    }
}

/// The guides at the placement the renderer is using right now.
///
/// Its own view, observing `AssistLiveState`: a pan is a drag, and the guides
/// have to follow it frame by frame. Watching the controller for that would
/// re-lay out the whole window per tick — the lag item 20 is about — so the
/// live values publish here and nowhere else.
private struct PlacedFramelines: View {
    @ObservedObject var live: AssistLiveState
    let viewport: CGSize
    let sourceSize: CGSize
    let ratio: Double?
    let safeAreas: Bool
    let actionPercent: Double
    let titlePercent: Double

    var body: some View {
        if let placed = live.assist.placement(sourceSize: sourceSize,
                                              in: viewport) {
            FramelinesOverlay(ratio: ratio, safeAreas: safeAreas,
                              actionPercent: actionPercent,
                              titlePercent: titlePercent)
                .frame(width: placed.rect.width, height: placed.rect.height)
                .position(x: placed.rect.midX, y: placed.rect.midY)
        }
    }
}

/// Framelines + safe areas inside the box it is given (which IS the picture —
/// see `AssistFramelines` for how the box gets there).
struct FramelinesOverlay: View {
    let ratio: Double?
    let safeAreas: Bool
    /// Action/title safe as a percentage of the frame. 93/90 is SMPTE RP 218,
    /// and the order matters: title safe is the inner box (see
    /// `CaptureSettings.safeActionPercent`).
    var actionPercent: Double = 93
    var titlePercent: Double = 90

    /// The frameline's box inside `size` — the safe areas live inside it, so
    /// both halves of the overlay ask for it the same way.
    private func framed(_ size: CGSize) -> CGRect {
        guard let ratio else { return CGRect(origin: .zero, size: size) }
        // explicit CGFloat: the CI toolchain can't resolve the mixed
        // Double/CGFloat arithmetic the local one accepts
        let r = CGFloat(ratio)
        let videoAspect = size.width / max(1, size.height)
        return r >= videoAspect
            ? CGRect(x: 0, y: (size.height - size.width / r) / 2,
                     width: size.width, height: size.width / r)
            : CGRect(x: (size.width - size.height * r) / 2, y: 0,
                     width: size.height * r, height: size.height)
    }

    /// A safe-area rect: `percent` of the frame, centered.
    private func safeRect(_ base: CGRect, percent: Double) -> CGRect {
        let inset = CGFloat((100 - min(100, max(50, percent))) / 200)
        return base.insetBy(dx: base.width * inset, dy: base.height * inset)
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                if ratio != nil {
                    let rect = framed(size)
                    Path { $0.addRect(rect) }
                        .stroke(.white.opacity(0.75), lineWidth: 1)
                    // matte the outside slightly so the frame reads instantly
                    Path { path in
                        path.addRect(CGRect(origin: .zero, size: size))
                        path.addRect(rect)
                    }
                    .fill(.black.opacity(0.35), style: FillStyle(eoFill: true))
                }
                if safeAreas {
                    // safe areas live INSIDE the frameline when one is set
                    let base = framed(size)
                    Path { $0.addRect(safeRect(base, percent: actionPercent)) }
                        .stroke(.white.opacity(0.45), lineWidth: 0.7)
                    Path { $0.addRect(safeRect(base, percent: titlePercent)) }
                        .stroke(.white.opacity(0.3), lineWidth: 0.7)
                }
            }
        }
    }
}
