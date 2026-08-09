import SwiftUI

/// Settings, the VANC monitor and the offload — a row of their own directly
/// under the takes panel, centred on it.
///
/// **Where they have been, and why this is the answer** (owner items 2, 16 and
/// the correction that produced this file). They started in the footer's
/// bottom-left corner, and left because the footer needs that width for the
/// codec and the record folder — the two things a whole day can be shot wrong
/// on, and the two an operator has to be able to READ while the camera rolls.
/// They then spent a release as their own PLATE under the takes panel, and the
/// plate was the complaint: three setup buttons in a box of their own, huddled
/// in the middle of a strip that existed for nothing else. Item 2 moved them
/// onto the window's top chrome instead — and that is what the owner is
/// correcting here: the takes panel sits on the right by default, so "the
/// window's top-right corner" and "the takes panel's top-right corner" are the
/// same pixels, and three setup icons floating in the corner of a panel they
/// have nothing to do with is what he sees.
///
/// Read across all four moves, every complaint has been about the CHROME rather
/// than the position — the box, then the corner. So: no box, no corner, no
/// material of its own. A bare row of icons standing under the panel, centred
/// on the panel's width, outside the panel's own plate. `ContentView.sidePanel`
/// puts it in the same column as the panel and inside the same horizontal
/// padding, so "centred on the column" and "centred on the panel" are one
/// statement and cannot drift apart.
///
/// It follows the panel from side to side for free, which is what the window
/// overlay was mounted on the window to achieve.
struct PanelUtilityButtons: View {
    @EnvironmentObject private var controller: CaptureController
    @Environment(\.openWindow) private var openWindow

    /// Icon size. A touch larger than the 13pt these were squeezed to in the
    /// title-bar band — they are not fitting under the traffic lights any more —
    /// and still under the player badges', because they are setup controls and
    /// the panel above them is the content.
    private static let iconSize: CGFloat = 14

    var body: some View {
        HStack(spacing: 18) {
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
        // The row hugs its three icons; the CENTRING is the frame around it, and
        // it is here rather than at the call site so the row cannot be mounted
        // uncentred. `maxWidth: .infinity` takes the column's width — the same
        // width the panel plate above it takes — and centres the icons in it.
        .fixedSize()
        .frame(maxWidth: .infinity)
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
