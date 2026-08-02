import SwiftUI

/// Compact utility strip under the takes panel: Settings, the VANC monitor and
/// the offload — and, while one is running, the job itself.
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
            // A card that has just been plugged in, asking. Above the running
            // job rather than below it: it is a question waiting on an answer,
            // and the readout under it is a job that needs none. Conditional
            // here for the same reason the status strip is — an app with no
            // card waiting pays nothing for it.
            if let card = controller.cardOffer {
                CardOfferBanner(card: card)
            }
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
            // The dailies queue, when one is running — its own strip rather
            // than a shared one because dailies and an offload legitimately
            // run at once, and one readout flickering between two jobs says
            // nothing about either.
            if let status = controller.dailiesStatus {
                DailiesStatusStrip(status: status, dailies: controller.dailies)
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
            // Both of these FOCUS a window that is already open rather than
            // doing nothing visible: the strip is on the main window, so a
            // Settings window behind it is exactly where these get clicked
            // twice (see AppWindows).
            Button {
                AppWindows.present(.settings, opening: openWindow)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 14))
            }
            .help(L("open_settings"))

            Button {
                AppWindows.present(.vancMonitor, opening: openWindow)
            } label: {
                Image(systemName: "waveform.badge.magnifyingglass")
                    .font(.system(size: 14))
            }
            .help(L("vanc_open_help"))

            // One button, not a menu (owner item 25). It was a dropdown of two
            // items because copying a card off and re-checking a disk copied
            // weeks ago are two halves of one job — but the second half then
            // lived behind an icon with no label, on a strip under the takes
            // panel, and nobody ever found it. It is a button on the offload
            // sheet's own footer now, which is where the operator already is.
            //
            // This strip is still the offload's only home in the window: the
            // export menu beside the takes cannot hold it, being disabled while
            // there are no takes, and an offload happens before there is one.
            Button {
                controller.showOffloadSheet()
            } label: {
                Image(systemName: "externaldrive.badge.checkmark")
                    .font(.system(size: 14))
            }
            .help(L("offload_menu_copy"))
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
