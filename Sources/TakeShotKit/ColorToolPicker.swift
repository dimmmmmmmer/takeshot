import CaptureCore
import SwiftUI

/// The exposure colour tool: off, false colour, or EL Zone.
///
/// Offered in the View menu and in the assist menu over the player, and written
/// out in both. The binding differs — the menu bar writes the stored aids, the
/// on-screen menu goes through the debounced draft — but the choices are one
/// list, and a fourth tool added to one of two copies is a tool half the app
/// does not have.
///
/// The style stays with the caller: inline in a menu, segmented on the player.
struct ColorToolPicker: View {
    @Binding var selection: ViewAssist.ColorTool

    var body: some View {
        Picker(L("assist_tool"), selection: $selection) {
            Text(L("assist_off")).tag(ViewAssist.ColorTool.off)
            Text(L("assist_false_color")).tag(ViewAssist.ColorTool.falseColor)
            Text(L("assist_el_zone")).tag(ViewAssist.ColorTool.elZone)
        }
    }
}
