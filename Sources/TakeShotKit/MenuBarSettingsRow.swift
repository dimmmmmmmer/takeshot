import SwiftUI

/// "Keep TakeShot in the menu bar" — the status item, and with it the ability
/// to see and drive a rolling take while the main window is closed or behind
/// other apps.
///
/// Its own view rather than one more line in `SettingsView.body`: that type is
/// the densest one in the app and is measured against a fixed window width, so
/// the row is worth being able to render on its own (see `ViewSettingsTests`).
struct MenuBarSettingsRow: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        Toggle(L("menubar_keep"), isOn: Binding(
            get: { controller.keepInMenuBar },
            // nil rather than false when switched back off: an install that
            // never touched it writes no field at all, which is what keeps an
            // older build able to decode the blob.
            set: { controller.settings.keepInMenuBar = $0 ? true : nil }))
    }
}
