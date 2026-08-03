import SwiftUI

/// Settings, the VANC monitor and the offload — on the main window's own top
/// chrome, opposite the traffic lights.
///
/// Where they have been and why they are here (owner items 2 and 16). They
/// started in the footer's bottom-left corner; the footer needs that width for
/// the codec and the record folder, which are the two things a whole day can be
/// shot wrong on and which an operator has to be able to READ while the camera
/// is rolling, so they left. They then spent a release as their own plate under
/// the takes panel, and that plate was the complaint: three setup buttons in a
/// box of their own, huddled in the middle of a strip that existed for nothing
/// else. Item 16 offered the alternative of spreading them across the panel's
/// width; item 2 asked for something better than either — just put them on the
/// window. So: no plate, no block, no row of its own. They sit in the band the
/// window already reserves under the title-bar buttons (`windowTopInset`),
/// which is otherwise empty space kept clear of the traffic lights.
///
/// Mounted on the WINDOW rather than in either column (see `ContentView`): the
/// takes panel sits on the left or the right depending on a setting, and these
/// belong in the window's top-right corner either way — opposite the traffic
/// lights, which is the one corner nothing else ever occupies.
struct WindowUtilityButtons: View {
    @EnvironmentObject private var controller: CaptureController
    @Environment(\.openWindow) private var openWindow

    /// Icon size in the band. Smaller than the player badges': this is chrome
    /// beside the window buttons, and it has `windowTopInset` (~26pt) to live
    /// in without pushing the player down.
    private static let iconSize: CGFloat = 13

    var body: some View {
        HStack(spacing: 14) {
            // Both of these FOCUS a window that is already open rather than
            // doing nothing visible: a Settings window behind the main one is
            // exactly where these get clicked twice (see AppWindows).
            button("gearshape", help: L("open_settings")) {
                AppWindows.present(.settings, opening: openWindow)
            }
            button("waveform.badge.magnifyingglass", help: L("vanc_open_help")) {
                AppWindows.present(.vancMonitor, opening: openWindow)
            }
            // One button, not a menu (owner item 25). Copying a card off and
            // re-checking a disk copied weeks ago are two halves of one job,
            // but the second half lived behind an unlabelled icon and nobody
            // ever found it; it is a button on the offload sheet's own footer
            // now, which is where the operator already is.
            //
            // This is still the offload's only home in the window: the export
            // menu beside the takes cannot hold it, being disabled while there
            // are no takes, and an offload happens before there is one.
            button("externaldrive.badge.checkmark", help: L("offload_menu_copy")) {
                controller.showOffloadSheet()
            }
        }
        .buttonStyle(.borderless)
        // hugging, not stretched: it is an overlay on the window's top band,
        // and a full-width one would lie across the strip the operator drags
        // the window by
        .fixedSize()
    }

    private func button(_ symbol: String, help: String,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: Self.iconSize))
        }
        .help(help)
    }
}

/// What is running right now, at the bottom of the takes panel: an offload, a
/// dailies queue, a card asking to be copied.
///
/// This is the half of the old utility strip that STAYS in the panel, and it
/// stays for a reason the owner gave in as many words — "оффлоад никак не
/// скрыть, статус на закрытом его окне не проверить": a job whose only readout
/// is inside its own sheet cannot be checked without reopening the sheet, which
/// is impractical on set. So the readout lives with the sheets closed, in the
/// panel, where there is width for a file name and a bar.
///
/// It is not a plate and not a block: with nothing running it renders nothing
/// at all — not even the spacing — so the panel is exactly the panel until
/// there is something to say.
struct PanelRunStatus: View {
    @EnvironmentObject private var controller: CaptureController

    private var isIdle: Bool {
        controller.cardOffer == nil && controller.offloadStatus == nil
            && controller.dailiesStatus == nil
    }

    var body: some View {
        if !isIdle {
            VStack(spacing: 6) {
                // A card just plugged in, asking. Above the running job rather
                // than below it: it is a question waiting on an answer, and the
                // readout under it is a job that needs none.
                if let card = controller.cardOffer {
                    CardOfferBanner(card: card)
                }
                if let status = controller.offloadStatus {
                    OffloadStatusStrip(status: status, offload: controller.offload,
                                       verify: controller.verify)
                }
                // The dailies queue gets its own strip rather than a shared
                // one: dailies and an offload legitimately run at once, and one
                // readout flickering between two jobs says nothing about either.
                if let status = controller.dailiesStatus {
                    DailiesStatusStrip(status: status, dailies: controller.dailies)
                }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, PanelChrome.contentMargin)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            // a hairline off the content above rather than a second material:
            // the panel already has one, and stacking them made the old strip
            // read as a separate box
            .overlay(alignment: .top) { Divider() }
        }
    }
}
