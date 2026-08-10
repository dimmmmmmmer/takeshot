import CaptureCore
import SwiftUI

/// The SRT section of the settings window.
///
/// Its own file rather than another block in `SettingsView`, like the remote's
/// section and for the same reason — that view is the densest localized surface in
/// the app and sits at the file-length ceiling.
///
/// **Six controls, and the shortlist is the feature.** NDI needed a switch and a
/// name because it announced itself; an SRT link has to be told where to send, in
/// which role, how much of a bad link to ride out and how many bits the link can
/// carry. None of those is a knob the app could infer — they are facts about the
/// venue that the operator has and the app does not. Everything else about the
/// stream IS inferred and stays off this pane: the codec, the keyframe interval,
/// the raster, the frame rate and the packet size.
///
/// The role picker's two labels carry their own explanation rather than a caption
/// under them ("Dial the receiver" / "Wait for the receiver"), because
/// caller-versus-listener is the one thing here a camera operator cannot be
/// expected to know and the label is where an answer costs nothing.
struct SRTSettingsSection: View {
    @EnvironmentObject private var controller: CaptureController

    /// Width shared by the four short numeric fields, so they line up.
    static let numberWidth: CGFloat = 90

    private var isOn: Bool { controller.settings.srt.enabled == true }

    private var isCaller: Bool {
        controller.settings.srt.roleEffective == .caller
    }

    var body: some View {
        Section(L("settings_srt")) {
            Toggle(L("srt_enable"), isOn: Binding(
                get: { isOn },
                // nil rather than false when switched off: an install that never
                // touched it writes no field at all, which is what keeps an older
                // build able to decode the blob.
                set: { controller.settings.srt.enabled = $0 ? true : nil }))
            if isOn {
                roleRow
                if isCaller { addressRow }
                portRow
                latencyRow
                bitrateRow
                passphraseRow
                // Its own view because the state lives on `mirrors`, a nested
                // observable — this is the `live` pattern: the row that shows a
                // value observes the object that publishes it, so the rest of the
                // settings window does not re-render with it.
                SRTStatusRow(mirrors: controller.mirrors)
            }
        }
    }

    private var roleRow: some View {
        Picker(L("srt_role"), selection: Binding(
            get: { controller.settings.srt.roleEffective },
            set: { controller.settings.srt.role = $0.rawValue })) {
                Text(L("srt_role_caller")).tag(SRTRole.caller)
                Text(L("srt_role_listener")).tag(SRTRole.listener)
        }
    }

    /// Where a caller dials. Absent for a listener, which binds every interface —
    /// a field that had to be left blank would be a field to get wrong.
    private var addressRow: some View {
        LabeledContent(L("srt_address")) {
            TextField("", text: Binding(
                get: { controller.settings.srt.address ?? "" },
                set: { controller.settings.srt.address =
                    $0.isEmpty ? nil : $0 }))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 180)
        }
    }

    private var portRow: some View {
        LabeledContent(L("srt_port")) {
            TextField("", value: Binding(
                get: { controller.settings.srt.portEffective },
                // Below 1024 needs root and above 65535 does not exist; a typo
                // either way would fail the open with an error naming a port the
                // operator never meant to ask for.
                set: { controller.settings.srt.port = min(65535, max(1024, $0)) }),
                format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: Self.numberWidth)
        }
    }

    /// SRT's delivery buffer: how long it has to notice a lost packet and ask for
    /// it again, paid for in delay. Clamped to what libsrt accepts.
    private var latencyRow: some View {
        LabeledContent(L("srt_latency")) {
            TextField("", value: Binding(
                get: { controller.settings.srt.latencyEffective },
                set: { controller.settings.srt.latencyMs =
                    min(8000, max(20, $0)) }),
                format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: Self.numberWidth)
        }
    }

    private var bitrateRow: some View {
        LabeledContent(L("srt_bitrate")) {
            TextField("", value: Binding(
                get: { controller.settings.srt.bitrateEffective },
                set: { controller.settings.srt.bitrateMbps =
                    min(100, max(0.5, $0)) }),
                format: .number.precision(.fractionLength(0...1)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: Self.numberWidth)
        }
    }

    /// AES, or nothing. A secure field because the stream it protects is a picture
    /// of the shoot going out over somebody else's network.
    private var passphraseRow: some View {
        LabeledContent(L("srt_passphrase")) {
            SecureField("", text: Binding(
                get: { controller.settings.srt.passphrase ?? "" },
                set: { controller.settings.srt.passphrase =
                    $0.isEmpty ? nil : $0 }))
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
        }
    }
}

/// Sending, or the reason it is not — and the address to read out to whoever is
/// at the other end.
///
/// Most builds of this app have no libsrt headers (CI's certainly does not), and
/// on a set the receiver is closed half the day, so "switched on" and "sending"
/// are different facts and the row says which one is true and why. Never a switch
/// left looking on over a link that does not exist.
struct SRTStatusRow: View {
    @ObservedObject private var mirrors: DisplayMirrors

    init(mirrors: DisplayMirrors) {
        self.mirrors = mirrors
    }

    var body: some View {
        LabeledContent(L("srt_status")) {
            VStack(alignment: .trailing, spacing: 4) {
                switch mirrors.srtState {
                case .sending:
                    Text(L("srt_sending"))
                    endpointText
                case .starting:
                    Text(L("srt_starting")).foregroundStyle(.secondary)
                    endpointText
                case .off:
                    Text(L("srt_not_sending")).foregroundStyle(.secondary)
                case .reconnecting(let reason):
                    Text(L("srt_reconnecting")).foregroundStyle(.secondary)
                    detail(reason)
                case .unavailable(let reason):
                    Text(L("srt_unavailable")).foregroundStyle(.secondary)
                    detail(reason)
                case .failed(let reason):
                    Text(L("srt_failed_short")).foregroundStyle(.secondary)
                    detail(reason)
                }
            }
        }
    }

    /// The URL the link is on, in the spelling a receiver is typed with — so it
    /// is a string to hand over rather than four fields to read back.
    @ViewBuilder private var endpointText: some View {
        if let url = mirrors.srtEndpoint?.url {
            detail(url)
        }
    }

    /// The reasons come from the bridge and are English, like every other
    /// CaptureCore/CDeckLink error: they name a shell command and a directory, and
    /// a translated path is a worse instruction than the path.
    private func detail(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: SettingsView.width * 0.6, alignment: .trailing)
            .fixedSize(horizontal: false, vertical: true)
    }
}
