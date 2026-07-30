import SwiftUI

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
