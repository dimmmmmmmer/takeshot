import SwiftUI

/// The margins the takes panel's chrome keeps from the panel edge.
enum PanelChrome {
    /// The margin the scrollable content keeps — the grids' own padding. The
    /// section headers end their rows on the same margin, so the view pickers
    /// finish where the content below them does instead of floating short of
    /// the panel's right edge (owner item 22).
    ///
    /// It is the margin on BOTH sides, and now genuinely so (owner item 44).
    /// The header already carried it either way; what made the pickers look
    /// further from the right edge than the title is from the left was inside
    /// the picker — a segmented control pinned to a 70pt frame it does not fill
    /// is centered in it, so ~14pt of its own box was empty. It hugs its icons
    /// now (see `ViewModePicker`), and the two inked margins come out equal.
    /// `ViewPanelTests.theSectionHeaderInsetsAreSymmetric` rasterizes the
    /// header and fails if they drift apart by more than half a point.
    static let contentMargin: CGFloat = 10
}

/// List-or-grid, and how big the tiles are.
///
/// The takes section and the Other content section carry the same pair in the
/// same corner, and each had its own copy — down to the slider's 70pt width.
/// They are one control to the operator's eye and have to stay one to the
/// layout, or the two headers stop lining up.
struct PanelViewControls: View {
    @Binding var viewMode: String
    @Binding var tileSize: Double

    var body: some View {
        if viewMode == "grid" {
            Slider(value: $tileSize, in: TakeTileBadges.tileWidthRange)
                .frame(width: 70)
                .controlSize(.mini)
                .help(L("tile_size"))
        }
        ViewModePicker(mode: $viewMode)
    }
}

/// A section header in the takes panel: whatever the section puts on the left,
/// and the shared list/grid controls hard against the right edge.
///
/// One view for both sections rather than a copy each. The two are read as one
/// column and their headers have to line up; they had already drifted once
/// (different vertical padding, and only one of them on the content margin),
/// and the symmetry item 44 is about cannot be asserted at all if there are two
/// places for it to be wrong in.
struct PanelSectionHeader<Leading: View>: View {
    @Binding var viewMode: String
    @Binding var tileSize: Double
    @ViewBuilder let leading: () -> Leading

    var body: some View {
        HStack(spacing: 10) {
            leading()
            Spacer(minLength: 4)
            PanelViewControls(viewMode: $viewMode, tileSize: $tileSize)
        }
        .padding(.horizontal, PanelChrome.contentMargin)
    }
}
