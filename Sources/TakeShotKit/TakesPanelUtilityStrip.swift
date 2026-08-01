import SwiftUI

/// Compact utility strip under the takes panel: Settings, the VANC monitor and
/// a verified offload copy — and, while one is running, the offload itself.
///
/// The first three used to be in the footer's bottom-left corner. They are
/// setup, not shooting — nobody opens Settings between takes — and the footer
/// needs the space for the codec and the record folder, which an operator does
/// have to read while the camera is rolling.
///
/// The strip is its own plate BELOW the panel, not a row inside it (owner
/// item 2): behind a Divider on the panel's own material it read as the Other
/// content section's chrome. The buttons sit centered on the panel's width;
/// the plate carries its own material because the window background behind it
/// is operator-configurable, and the offload readout has to stay readable on
/// any of it.
struct TakesPanelUtilityStrip: View {
    @EnvironmentObject private var controller: CaptureController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 6) {
            buttons
            // The live run, when there is one (see OffloadStatusStrip). Under
            // the buttons rather than beside them: it is three lines of text
            // and a bar, and the row above is icons. Its lines keep their own
            // leading alignment against the centered buttons — it is a readout,
            // and centered ragged text is harder to scan. Conditional HERE
            // rather than inside the strip so that an idle app pays nothing for
            // it, not even this VStack's spacing.
            if let status = controller.offloadStatus {
                OffloadStatusStrip(status: status, offload: controller.offload,
                                   verify: controller.verify)
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(.white.opacity(0.07)))
    }

    private var buttons: some View {
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

            // A menu rather than a button since there are two halves of the same
            // job: copying a card off, and re-checking a disk that was copied
            // weeks ago. This strip is their only home — the export menu beside
            // the takes cannot hold them, because it is disabled while there are
            // no takes and both of these happen before there is one.
            Menu {
                Button(L("offload_menu_copy")) { controller.showOffloadSheet() }
                Button(L("verify_menu")) { controller.chooseDiskToVerify() }
            } label: {
                Image(systemName: "externaldrive.badge.checkmark")
                    .font(.system(size: 14))
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L("offload_menu_group"))
        }
    }
}

extension View {
    /// Mounts the utility strip BELOW the takes panel as its own plate — the
    /// buttons are centered on the panel's width but do not share its chrome
    /// (owner item 2).
    ///
    /// A modifier rather than a container so the panel's mount site needs
    /// exactly one line for it.
    func takesPanelUtilityStrip() -> some View {
        VStack(spacing: 8) {
            self
            TakesPanelUtilityStrip()
        }
    }
}
