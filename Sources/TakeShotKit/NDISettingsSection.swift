import SwiftUI

/// The NDI section of the settings window: the switch, the name the source is
/// announced under, and what is actually happening.
///
/// Its own file rather than another block in `SettingsView`, like the remote's
/// and the SRT section and for the same reason — that view is the densest
/// localized surface in the app and sits at the file-length ceiling.
///
/// **Two controls, against SRT's six, and the difference is the whole reason
/// both features exist.** NDI ANNOUNCES itself and a receiver picks it out of a
/// list, so the app needs a switch and a name and nothing else — no address, no
/// port, no role, no latency, because there is no handshake for an operator to
/// be on the wrong side of. SRT is a transport and every one of those is a fact
/// about the venue that only the operator has. That is what "NDI beside SRT"
/// buys: on a set where the receiver is on the same LAN, NDI is two controls;
/// where it is across a network somebody else runs, SRT is the one that can get
/// there.
///
/// The status row is the point of this section. Most builds of this app have no
/// NDI SDK (CI's certainly does not), so "switched on" and "sending" are
/// different facts, and the row says which one is true and why — never a switch
/// left looking on over a source that does not exist.
struct NDISettingsSection: View {
    @EnvironmentObject private var controller: CaptureController

    private var isOn: Bool { controller.settings.ndi.enabled == true }

    var body: some View {
        Section(L("settings_ndi")) {
            Toggle(L("ndi_enable"), isOn: Binding(
                get: { isOn },
                // nil rather than false when switched off: an install that never
                // touched it writes no field at all, which is what keeps an
                // older build able to decode the blob.
                set: { controller.settings.ndi.enabled = $0 ? true : nil }))
            if isOn {
                nameRow
                // Its own view because the state lives on `mirrors`, a nested
                // observable — this is the `live` pattern: the row that shows a
                // value observes the object that publishes it, so the rest of
                // the settings window does not re-render with it.
                NDIStatusRow(mirrors: controller.mirrors)
            }
        }
    }

    /// The name receivers see. Announced as "MACHINE (name)" — the machine half
    /// is the runtime's, so this field is the project and the camera.
    private var nameRow: some View {
        LabeledContent(L("ndi_source_name")) {
            TextField("", text: Binding(
                get: { controller.settings.ndi.sourceName
                    ?? controller.settings.ndi.sourceNameEffective(
                        controller.settings.naming) },
                // Empty means "back to the default", which is the effective name
                // the placeholder above is already showing.
                set: { controller.settings.ndi.sourceName =
                    $0.isEmpty ? nil : $0 }))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 180)
        }
    }

}

/// Sending, or the reason it is not.
///
/// **The reason is a paragraph in a localized panel, so it is localized.** It
/// used to come out of the bridge in English under a Russian label, which is
/// the defect `BridgeUnavailable` exists to fix: the bridge states which of its
/// four causes this is and the words are picked here, at draw time, so the row
/// follows the language switch like every other string in this window. The path
/// and the file name inside those sentences are NOT translated — they are
/// things to type, and a translated path is a worse instruction than the path.
struct NDIStatusRow: View {
    @ObservedObject private var mirrors: DisplayMirrors

    init(mirrors: DisplayMirrors) {
        self.mirrors = mirrors
    }

    var body: some View {
        LabeledContent(L("ndi_status")) {
            VStack(alignment: .trailing, spacing: 4) {
                switch mirrors.ndiState {
                case .sending:
                    Text(L("ndi_sending"))
                    // Which runtime is actually loaded. Free to show, and the
                    // first thing worth knowing when a receiver on the set
                    // cannot see a source that says it is sending.
                    if let version = NDISender.runtimeVersion {
                        reasonText(version)
                    }
                case .announced:
                    // On the network, nobody watching. Said plainly rather
                    // than as "sending", which is what it used to claim.
                    Text(L("ndi_announced")).foregroundStyle(.secondary)
                    if let version = NDISender.runtimeVersion {
                        reasonText(version)
                    }
                case .off:
                    Text(L("ndi_not_sending")).foregroundStyle(.secondary)
                case .unavailable(let reason):
                    Text(L("ndi_unavailable")).foregroundStyle(.secondary)
                    reasonText(reason.localizedText)
                case .failed(let reason):
                    Text(L("ndi_failed_short")).foregroundStyle(.secondary)
                    reasonText(reason)
                }
                // A runtime that carries no sound still sends the picture, and
                // said here rather than left to be discovered on the receiver:
                // "the feed has no audio" is a question somebody asks from
                // another room, halfway through a take.
                if mirrors.ndiCarriesAudio == false {
                    // Short enough to stay on ONE line in both languages — a
                    // grouped Form wraps rather than truncates, and a row that
                    // wraps in Russian only makes the section a different
                    // height in the two languages (`ViewNDISettingsTests`).
                    // The sentence is in the tooltip.
                    Text(L("ndi_picture_only"))
                        .foregroundStyle(.orange)
                        .help(L("ndi_picture_only_help"))
                }
            }
        }
    }

    private func reasonText(_ reason: String) -> some View {
        Text(reason)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: SettingsView.width * 0.6, alignment: .trailing)
            .fixedSize(horizontal: false, vertical: true)
    }
}
