import CaptureCore
import SwiftUI

// The exposure legend: the one operator aid that is chrome rather than a mark
// on the picture, so it stays a SwiftUI overlay.
//
// Split out of AssistMenu (which owns the popover that switches the aids on) —
// this is what the fullscreen windows and the main player share, and it is the
// one that has to know where the rest of the chrome is.

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
    /// It went from 108 to 120 when the slate moved into the footer as a second
    /// row of fields (owner item 27) — the band the legend has to clear is the
    /// footer's real height, and that is now 101pt.
    static let fullscreenBottomInset: CGFloat = 120
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

// Framelines and safe areas used to be a third view in this file, drawn over
// the player and transformed onto the picture through `ViewAssist.placement`.
// They are not a view any more: an overlay reaches the surface it is mounted
// on and nothing else, which is why the director's monitor and the hardware
// output never showed them (owner item 7). They are drawn into the display
// frame instead — `AssistGuides` in CaptureCore — where the punch-in and the
// letterbox carry them along with the picture because they ARE the picture.
