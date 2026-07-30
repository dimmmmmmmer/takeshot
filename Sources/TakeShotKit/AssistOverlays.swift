import CaptureCore
import SwiftUI

// What the operator aids draw ON TOP of the picture: the exposure legend, the
// framelines and the safe-area guides.
//
// Split out of AssistMenu (which owns the popover that switches them on) —
// these three are what the fullscreen windows and the main player share, and
// they are the ones that have to know where the chrome is and where the
// punched-in image has moved to.

// MARK: - legend size and corner

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
                                       horizontalPadding: 8, verticalPadding: 4,
                                       cornerRadius: 6)
        case .medium:
            return AssistLegendMetrics(swatchHeight: 11, falseColorWidth: 40,
                                       elZoneWidth: 29, fontSize: 9,
                                       horizontalPadding: 10, verticalPadding: 5,
                                       cornerRadius: 7)
        case .large:
            return AssistLegendMetrics(swatchHeight: 15, falseColorWidth: 52,
                                       elZoneWidth: 38, fontSize: 12,
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
    var horizontalPadding: CGFloat
    var verticalPadding: CGFloat
    var cornerRadius: CGFloat
}

/// Which corner of the player the legend sits in.
enum AssistLegendCorner: String, CaseIterable, Identifiable {
    case topLeading
    case topTrailing
    case bottomLeading
    case bottomTrailing

    var id: String { rawValue }

    var alignment: Alignment {
        switch self {
        case .topLeading: return .topLeading
        case .topTrailing: return .topTrailing
        case .bottomLeading: return .bottomLeading
        case .bottomTrailing: return .bottomTrailing
        }
    }

    var labelKey: String {
        switch self {
        case .topLeading: return "corner_top_left"
        case .topTrailing: return "corner_top_right"
        case .bottomLeading: return "corner_bottom_left"
        case .bottomTrailing: return "corner_bottom_right"
        }
    }

    var isTop: Bool { self == .topLeading || self == .topTrailing }
}

/// How far the legend stays off each edge of the player.
///
/// The player's own chrome is what these numbers are made of. In fullscreen the
/// footer and the transport auto-hide, but they come back in the same place the
/// moment the pointer goes near them — a legend tucked into the bottom of the
/// screen there disappears under the controls exactly when the operator reaches
/// for them, which is what item 2 was about.
enum AssistLegendPlacement {
    /// Clears the badge row over the image (8pt inset + the badge itself).
    static let topInset: CGFloat = 44
    /// Clears the transport bar the player floats at its bottom edge.
    static let bottomInset: CGFloat = 56
    /// Clears the fullscreen footer/transport band (the bar plus the 18pt it is
    /// lifted by). `ViewAssistToolsTests` measures the real bars against this.
    static let fullscreenBottomInset: CGFloat = 108
    static let sideInset: CGFloat = 12

    static func insets(corner: AssistLegendCorner,
                       fullscreen: Bool) -> EdgeInsets {
        let bottom = fullscreen ? fullscreenBottomInset : bottomInset
        return EdgeInsets(
            top: corner.isTop ? topInset : 0,
            leading: sideInset,
            bottom: corner.isTop ? 0 : bottom,
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
        let metrics = size.metrics
        let swatchWidth = tool == .elZone
            ? metrics.elZoneWidth : metrics.falseColorWidth
        HStack(spacing: 1) {
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
        .padding(.horizontal, metrics.horizontalPadding)
        .padding(.vertical, metrics.verticalPadding)
        .background(.black.opacity(0.65),
                    in: RoundedRectangle(cornerRadius: metrics.cornerRadius))
    }
}

/// The legend in the corner the operator chose, clear of the chrome.
struct AssistLegendOverlay: View {
    @EnvironmentObject private var controller: CaptureController
    /// The fullscreen windows hide their chrome until the pointer asks for it.
    var fullscreen = false

    var body: some View {
        let tool = controller.assist.colorTool
        if tool != .off {
            let corner = controller.legendCorner
            ZStack(alignment: corner.alignment) {
                Color.clear
                AssistLegend(tool: tool, size: controller.legendSize)
                    .padding(AssistLegendPlacement.insets(corner: corner,
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
