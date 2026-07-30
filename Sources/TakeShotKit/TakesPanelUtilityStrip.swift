import SwiftUI

/// Compact utility strip along the bottom of the takes panel: Settings, the VANC
/// monitor and a verified offload copy.
///
/// All three used to be in the footer's bottom-left corner. They are setup, not
/// shooting — nobody opens Settings between takes — and the footer needs the
/// space for the codec and the record folder, which an operator does have to read
/// while the camera is rolling. Here they sit under the Other content block,
/// where the only thing they compete with is the panel's own width.
struct TakesPanelUtilityStrip: View {
    @EnvironmentObject private var controller: CaptureController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 14) {
            Button {
                openWindow(id: "settings")
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 14))
            }
            .help(L("open_settings"))

            Button {
                openWindow(id: "vanc-monitor")
            } label: {
                Image(systemName: "waveform.badge.magnifyingglass")
                    .font(.system(size: 14))
            }
            .help(L("vanc_open_help"))

            Button {
                // showOffloadSheet() does not exist in this worktree; the folder
                // offload is reached through its own two dialogs (see +Offload).
                controller.offloadFolder()
            } label: {
                Image(systemName: "externaldrive.badge.plus")
                    .font(.system(size: 14))
            }
            .help(L("offload_menu"))

            Spacer(minLength: 0)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

extension View {
    /// Mounts the utility strip at the BOTTOM of the takes panel — under the
    /// Other content block whenever there is one, and under the takes list when
    /// there is not (the buttons have to be reachable either way).
    ///
    /// A modifier rather than a container so the panel itself needs exactly one
    /// line for it.
    func takesPanelUtilityStrip() -> some View {
        VStack(spacing: 0) {
            self
            Divider()
            TakesPanelUtilityStrip()
        }
    }
}
