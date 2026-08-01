import SwiftUI

/// The margin the takes panel's scrollable content keeps from the panel edge —
/// the grids' own padding. The section headers end their rows on the same
/// margin, so the view pickers finish where the content below them does
/// instead of floating short of the panel's right edge (owner item 22).
enum PanelChrome {
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
