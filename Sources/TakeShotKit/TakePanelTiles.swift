import AppKit
import CaptureCore
import SwiftUI

// MARK: - badge geometry

/// Where a grid tile puts the badges it lays over its thumbnail.
///
/// The comment + circle-take cluster sits top-trailing, the duration pill
/// bottom-leading. At the small end of the tile-size slider there is no room
/// for both: a 70pt tile gives a 16:9 thumbnail 39pt of height and the two
/// badges want 49, so they printed straight over each other and the duration
/// was unreadable.
///
/// Below the threshold the duration moves off the picture and onto the caption
/// line next to the file name. The marks are what an operator scans a grid of
/// tiles for — comment set, take circled — so they are the ones that keep their
/// place on the image at every size; the duration is text and reads just as well
/// beside the name.
enum TakeTileBadges {
    /// Inset of either badge from the thumbnail edge.
    static let inset: CGFloat = 4
    /// Rendered height of the controls cluster inside its capsule: an 18pt icon
    /// row plus 4pt of capsule padding a side. Pinned against the real render
    /// by ViewTakesTileTests — a taller cluster would start colliding again.
    static let controlsHeight: CGFloat = 26
    /// Rendered height of the duration pill on the image (a caption2 line plus
    /// 1pt a side).
    static let durationHeight: CGFloat = 15
    /// Rendered height of the photo/video type glyph an Other-content tile
    /// carries. Same plate and the same caption2 metrics as the duration pill,
    /// so the two badges on such a tile are one family; pinned by
    /// ViewTakesTileTests against the real render.
    static let typeBadgeHeight: CGFloat = 15
    /// The aspect a tile fits its thumbnail to.
    static let aspect: CGFloat = 16 / 9
    /// The tile-size slider's range, in both panel sections.
    static let tileWidthRange: ClosedRange<Double> = 70...260

    static func thumbnailHeight(tileWidth: CGFloat) -> CGFloat {
        tileWidth / aspect
    }

    /// Whether a thumbnail this tall can carry both badges with a clear gap
    /// between them (one inset above, one below, one in the middle).
    static func bothFitOnImage(thumbnailHeight: CGFloat) -> Bool {
        thumbnailHeight >= controlsHeight + durationHeight + 3 * inset
    }

    /// The same question for an Other-content tile, whose two badges are the
    /// type glyph and the length-or-size pill. They share the leading edge —
    /// glyph above, pill below — so it is their heights that decide, and both
    /// are smaller than the takes' controls capsule.
    static func typeAndMetricFitOnImage(thumbnailHeight: CGFloat) -> Bool {
        thumbnailHeight >= typeBadgeHeight + durationHeight + 3 * inset
    }

    /// The rect the controls cluster occupies inside a thumbnail — top-trailing,
    /// inset. Origin top-left, like the overlay alignment it describes.
    static func controlsFrame(size: CGSize, in bounds: CGSize) -> CGRect {
        CGRect(x: bounds.width - inset - size.width, y: inset,
               width: size.width, height: size.height)
    }

    /// The rect the duration pill occupies inside a thumbnail — bottom-leading,
    /// inset.
    static func durationFrame(size: CGSize, in bounds: CGSize) -> CGRect {
        CGRect(x: inset, y: bounds.height - inset - size.height,
               width: size.width, height: size.height)
    }
}

// MARK: - the picture a tile shows

/// A tile's picture: a 16:9 black plate with the thumbnail fitted inside it.
///
/// The plate is what carries the size, and the picture is an OVERLAY on it. That
/// is the whole point of the shape. It used to be a `ZStack` of the plate and a
/// `.scaledToFill()` image under `.aspectRatio(16/9, contentMode: .fit)`, and
/// that combination cannot hold a tile: fill answers a proposal with a size that
/// COVERS it, so a portrait frame reported a height several times the tile's
/// width, the stack took the larger of its two children, and `.aspectRatio`
/// hands back whatever its child measured. One vertical clip in the folder and
/// the grid grew a tile taller than the panel.
///
/// An overlay cannot resize its host, whatever it measures, so the cell is 16:9
/// for every source there is. Inside it the picture is FITTED, not filled:
/// letterboxed against the black matte. Cropping a portrait frame to a landscape
/// box would be the alternative, and it would show the operator a framing the
/// camera never shot.
struct TakeTileThumbnail<Fallback: View>: View {
    let image: NSImage?
    @ViewBuilder let fallback: () -> Fallback

    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(.black)
            .aspectRatio(TakeTileBadges.aspect, contentMode: .fit)
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    fallback()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - the badges themselves

/// Comment + circle-take marks as they sit on a thumbnail: a dark capsule so
/// they stay legible over a blown-out frame.
struct TakeTileControls: View {
    let take: Take

    var body: some View {
        HStack(spacing: 4) {
            TakeLogButton(take: take)
            RatingToggle(take: take)
        }
        .padding(TakeTileBadges.inset)
        .background(.black.opacity(0.45), in: Capsule())
    }
}

/// One short fact about a tile's clip — a take's length, or an Other-content
/// item's length or pixel size. On the image it needs its own dark plate; on the
/// caption line under the tile it is just secondary text next to the name.
struct TileMetricBadge: View {
    let text: String
    var onImage = true

    var body: some View {
        if onImage {
            label
                .padding(.horizontal, TakeTileBadges.inset)
                .padding(.vertical, 1)
                .background(.black.opacity(0.6),
                            in: RoundedRectangle(cornerRadius: 3))
                .foregroundStyle(.white)
        } else {
            label.foregroundStyle(.secondary)
        }
    }

    /// One line, always (owner item 43).
    ///
    /// A duration is four characters and a pixel size is nine ("6000×4000"), and
    /// on the caption line of the smallest tile the long one wrapped into a
    /// column — which does not just look wrong, it makes that tile taller than
    /// its neighbours and breaks the grid's row. `lineLimit(1)` alone would
    /// truncate it into "6000×…", so the badge keeps its full width
    /// (`fixedSize`) and the FILE NAME beside it gives way instead: the name is
    /// already middle-truncated and reads fine short, the size does not.
    private var label: some View {
        Text(text)
            .font(.caption2.monospacedDigit())
            .lineLimit(1)
            .fixedSize()
    }
}

/// Take length, in the shared metric plate.
struct TakeDurationBadge: View {
    let seconds: Double
    var onImage = true

    var body: some View {
        TileMetricBadge(text: durationText(seconds), onImage: onImage)
    }
}

// MARK: - selection chrome and clicks

extension View {
    /// Accent outline on a selected tile or row. An overlay, so showing it
    /// cannot move anything: the panel's width budget is measured to the point.
    func panelSelectionOutline(_ selected: Bool, tint: Color,
                               cornerRadius: CGFloat = 8) -> some View {
        overlay(RoundedRectangle(cornerRadius: cornerRadius)
            .strokeBorder(tint, lineWidth: 2)
            .opacity(selected ? 1 : 0))
    }

    /// The click behaviour every item in the takes panel shares: one click
    /// selects (cmd toggles, shift extends the range), two open the clip.
    ///
    /// The modifiers are read off `NSEvent` inside the handler rather than
    /// declared with `TapGesture.modifiers`. That variant needs one gesture per
    /// combination AND the unmodified gesture still fires alongside them, so a
    /// cmd-click toggled the item and was immediately overwritten by the plain
    /// "select this one alone".
    func panelItemClicks(_ url: URL, in controller: CaptureController,
                         open: @escaping () -> Void) -> some View {
        contentShape(Rectangle())
            .onTapGesture(count: 2, perform: open)
            .onTapGesture {
                controller.clickPanelItem(url, modifiers: NSEvent.modifierFlags)
            }
    }
}

// MARK: - counted strings

/// "3 items" in the UI language, with Russian's three plural forms.
///
/// A `.stringsdict` would normally do this, but it picks its form with
/// `Locale.current` — and the app chooses its UI language itself by swapping
/// the .lproj bundle (see L10n), so on an English Mac running the Russian UI
/// the rule applied would be the wrong language's. Hence the arithmetic here.
func localizedItemCount(_ count: Int) -> String {
    let lastDigit = abs(count) % 10
    let lastTwo = abs(count) % 100
    if lastDigit == 1, lastTwo != 11 {
        return L("item_count_one", count)
    }
    if (2...4).contains(lastDigit), !(12...14).contains(lastTwo) {
        return L("item_count_few", count)
    }
    return L("item_count_many", count)
}
