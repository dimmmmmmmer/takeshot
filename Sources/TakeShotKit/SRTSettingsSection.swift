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

    var body: some View {
        Section(L("settings_srt")) {
            Toggle(L("srt_enable"), isOn: Binding(
                get: { isOn },
                // nil rather than false when switched off: an install that never
                // touched it writes no field at all, which is what keeps an older
                // build able to decode the blob.
                set: { controller.settings.srt.enabled = $0 ? true : nil }))
            if isOn {
                addressRow
                bitrateRow
                passphraseRow
                SRTEncoderRows(controller: controller)
                // **Start sits ON the status row**, which is the row that
                // says whether anything is going out. It was a row of its own
                // holding one button against the right margin, and read as a
                // stray (owner: "не нравится что у обоих источников кнопка
                // старт как-то несуразно выглядит сбоку отдельной строчкой").
                // A control belongs beside the reading it changes.
                //
                // Its own view because the state lives on `mirrors`, a nested
                // observable — this is the `live` pattern: the row that shows a
                // value observes the object that publishes it, so the rest of the
                // settings window does not re-render with it.
                SRTStatusRow(mirrors: controller.mirrors)
            }
        }
    }

    /// **The whole link, as one address.**
    ///
    /// Port, connection type and stream ID used to be rows of their own, and a
    /// pasted URL was taken apart across them — which is backwards twice over:
    /// none of the three is a setting an operator decides (they are parts of an
    /// address somebody handed them), and a paste that scatters itself is
    /// harder to read back than the line they were given (owner: "и все еще
    /// тут есть порт, delivery buffer и connection type — обсуждали же что это
    /// не настройки"; "разложило мне все по разным полям (это скорее минус чем
    /// плюс)").
    ///
    /// So the field holds what a receiver is typed with, and the parts stay
    /// where the operator can see them: `srt://host:port?mode=…&streamid=…`.
    /// A listener is `srt://:port?mode=listener`, which is how ffmpeg and
    /// libsrt's own tools spell it. What is NOT in it is the passphrase, which
    /// has a secure field of its own, and the delivery buffer, which the link
    /// measures for itself and the status row reports.
    private var addressRow: some View {
        LabeledContent(L("srt_address")) {
            SRTAddressField(settings: $controller.settings)
        }
    }

    /// SRT's delivery buffer: how long it has to notice a lost packet and ask
    /// for it again, paid for in delay.
    ///
    /// **Shown, not asked** (owner: "пусть это не на пользователе будет а
    /// автоматом считается"). It was a number field, which put a question to
    /// the operator that the link itself answers: the buffer wants to be about
    /// four round trips, and the round trip is something SRT measures and
    /// reports. `SRTMirror` reads it and re-opens on it; this row is where the
    /// operator can see what it decided, which is the difference between an
    /// automatic value and a hidden one.
    /// Four things it can say: a measured link, a link still being measured, a
    /// link this build cannot measure, and a figure that came from the address
    /// the operator pasted.
    private var latencyText: String {
        Self.latencyText(mirrors: controller.mirrors,
                         srt: controller.settings.srt)
    }

    /// The sentence for the latency row, out of the two values it reads.
    ///
    /// A static over its inputs rather than a computed property over an
    /// `@EnvironmentObject`, so the suite can read the four sentences
    /// directly: rendering the row and comparing sizes says that the row
    /// changed and not WHICH of the four it changed to — and the finding here
    /// is precisely that two of them used to be one sentence.
    static func latencyText(mirrors: DisplayMirrors,
                            srt: SRTSettings) -> String {
        let buffer = mirrors.srtLatencyMs ?? srt.latencyEffective
        if srt.latencyMs != nil {
            return L("srt_latency_stated", buffer)
        }
        guard let rtt = mirrors.srtRoundTripMs else {
            // FOUR things it can say. A libsrt without `srt_bstats` cannot
            // report a round trip at all, and saying "measuring" over that is
            // a promise the build cannot keep — for the whole day, on the one
            // row an operator opens to find out why the picture breaks up.
            return mirrors.srtCanMeasureRoundTrip
                ? L("srt_latency_measuring", buffer)
                : L("srt_latency_unmeasurable", buffer)
        }
        return L("srt_latency_auto", buffer, Int(rtt.rounded()))
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
                .controlSize(.small)
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
                // the same height as the address above it and the bitrate
                // between them — see `SRTAddressField.fontSize`
                .controlSize(.small)
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
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                reading
                // The control beside the reading it changes — see `StreamRunRow`.
                StreamRunRow(mirrors: mirrors, kind: .srt)
            }
        }
    }

    private var reading: some View {
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
                detail(reason.localizedText)
            case .failed(let reason):
                Text(L("srt_failed_short")).foregroundStyle(.secondary)
                detail(reason)
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

    /// One line of small secondary text under the status word: an endpoint URL,
    /// a libsrt reconnect reason, or the localized paragraph a
    /// `BridgeUnavailable` produces. The shell command and the directory inside
    /// that paragraph are NOT translated — they are things to type, and a
    /// translated path is a worse instruction than the path.
    private func detail(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: SettingsView.width * 0.6, alignment: .trailing)
            .fixedSize(horizontal: false, vertical: true)
    }
}
