import CaptureCore
import SwiftUI

/// The one field the SRT section asks an operator to fill in.
///
/// **Committed, not typed through.** The old field parsed on every keystroke,
/// so a URL being typed by hand was taken apart half-finished — "srt://192.1"
/// is a host, and the port and mode it had not reached yet were applied from
/// whatever was left over. It commits on Return and on the way out instead,
/// which is also how the assist panel's typed boxes work (`AssistCustomField`),
/// and for the same reason.
///
/// **Fixed width.** The field used to grow with its content, and a MediaMTX
/// publish URL is a hundred characters — it stretched the row, stretched the
/// settings box and pushed the layout out of the window (owner: "длинный адрес
/// srt увеличивает строчку его ввода, увеличивает бокс и ломает ui"). The text
/// scrolls inside a field of a fixed size now, which is what every other long
/// value in this pane does.
struct SRTAddressField: View {
    @Binding var settings: CaptureSettings

    @State private var text = ""
    /// What the box was last set to by something other than typing — see
    /// `AssistCustomField.written`, which carries the same guard for the same
    /// reason: a commit on the way out must not re-apply a value nobody typed.
    @State private var written = ""
    @FocusState private var editing: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .frame(width: Self.width)
            .focused($editing)
            .onSubmit(commit)
            .onChange(of: editing) { _, focused in
                if !focused { commit() }
            }
            .onAppear { sync() }
            .onChange(of: settings.srt.addressURL) { _, _ in
                if !editing { sync() }
            }
            .help(L("srt_address_help"))
    }

    /// Wide enough for `srt://192.168.1.119:8890` and no wider: a stream ID is
    /// forty characters of hex and no field on this pane could hold one.
    static let width: CGFloat = 220

    private func sync() {
        text = settings.srt.addressURL
        written = text
    }

    private func commit() {
        guard text != written else { return }
        defer { sync() }
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = SRTAddress.parse(typed) else {
            // Nothing usable in it: the address is cleared rather than left
            // holding the last good one, so the status row says "no address"
            // instead of the link quietly going somewhere else.
            settings.srt.address = typed.isEmpty ? nil : typed
            return
        }
        settings.srt.address = parsed.host.isEmpty ? nil : parsed.host
        if let port = parsed.port { settings.srt.port = port }
        // An empty host with a port IS a listener, whether or not the URL said
        // so — there is nothing to dial.
        settings.srt.role = (parsed.mode
            ?? (parsed.host.isEmpty ? SRTRole.listener.rawValue : nil))
        settings.srt.latencyMs = parsed.latencyMs.map { min(8000, max(20, $0)) }
        settings.srt.streamID = parsed.streamID
        // **A pasted URL is authoritative about encryption.** A query with no
        // `passphrase=` says the link is unencrypted, which is what ffmpeg, OBS
        // and libsrt's own tools mean by it. A passphrase left in the field
        // from an earlier experiment used to survive the paste, so the app
        // dialled a plain endpoint with AES-128 — refused at the handshake,
        // reported as a link loss, and retried for ever without saying why
        // (owner: "и все равно не работает").
        if parsed.hadQuery || parsed.passphrase != nil {
            settings.srt.passphrase = parsed.passphrase
        }
    }
}
