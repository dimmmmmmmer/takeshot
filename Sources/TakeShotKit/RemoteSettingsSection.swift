import SwiftUI

/// The Remote section of the settings window: the switch, the port, the code,
/// and the address a phone can reach one of the three pages on.
///
/// Its own file rather than another block in `SettingsView`: that view is
/// already the densest localized surface in the app and close enough to the
/// file-length ceiling that the next section would have pushed a comment out to
/// make room.
///
/// One link row, not three. Each page used to get its own row and its own QR
/// code, which made this section taller than the settings window on a laptop
/// screen — and two of the three codes were always the wrong one to scan. The
/// page is picked with a segmented switch (the idiom the exposure tool and the
/// rec/playback control already use) and the row below it follows.
struct RemoteSettingsSection: View {
    @EnvironmentObject private var controller: CaptureController

    /// How wide the QR code is drawn. Big enough that a phone camera locks on
    /// from arm's length across a cart, small enough to leave the settings
    /// window its fixed width.
    static let qrSide: CGFloat = 132

    /// Which page the row and the code point at. View state: it is a question
    /// about what the operator is reading out right now, not a preference the
    /// app should still remember next shoot.
    @State private var link: RemoteLink = .remote

    private var isOn: Bool { controller.settings.remoteEnabled == true }

    var body: some View {
        Section(L("settings_remote")) {
            Toggle(L("remote_enable"), isOn: Binding(
                get: { isOn },
                set: { controller.settings.remoteEnabled = $0 ? true : nil }))
            if isOn {
                portRow
                pinRow
                pageRow
                addressRow
            }
        }
    }

    private var portRow: some View {
        LabeledContent(L("remote_port")) {
            TextField("", value: Binding(
                get: { controller.settings.remotePortEffective },
                // Below 1024 needs root and above 65535 does not exist; a typo
                // either way would take the listener down with an error the
                // operator cannot act on.
                set: { controller.settings.remotePort = min(65535, max(1024, $0)) }),
                format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 76)
        }
    }

    private var pinRow: some View {
        LabeledContent(L("remote_pin")) {
            HStack(spacing: 10) {
                Text(controller.settings.remotePIN ?? "----")
                    .font(.system(.title3, design: .monospaced))
                    .textSelection(.enabled)
                Button(L("remote_pin_new")) { controller.regenerateRemotePIN() }
            }
        }
    }

    /// Which page the address below is for.
    private var pageRow: some View {
        Picker(L("remote_page"), selection: $link) {
            ForEach(RemoteLink.allCases) { target in
                Text(L(target.labelKey)).tag(target)
            }
        }
        .pickerStyle(.segmented)
    }

    /// The addresses for the chosen page, and a code for the first of them.
    ///
    /// The addresses are the machine's own, filtered and ordered by
    /// `RemoteAddress` — loopback, link-local, tunnels and virtual bridges
    /// never appear, and the one a phone on the set network would use is
    /// first.
    @ViewBuilder private var addressRow: some View {
        let urls = controller.remoteURLs(for: link)
        LabeledContent(L("remote_address")) {
            VStack(alignment: .trailing, spacing: 4) {
                if controller.remoteBoundPort == 0 {
                    Text(L("remote_not_listening")).foregroundStyle(.secondary)
                } else if urls.isEmpty {
                    // No usable IPv4 at all: nothing to read out, and saying so
                    // beats an empty row the operator reads as a bug.
                    Text(L("remote_no_network")).foregroundStyle(.secondary)
                } else {
                    ForEach(urls, id: \.self) { url in
                        Text(url)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
        }
        if let first = urls.first, controller.remoteBoundPort > 0,
           // Regenerated per render rather than cached: a QR of a 30-character
           // URL is about a millisecond, and the settings pane is not a hot
           // path — a cache here would be a stale-address bug waiting to
           // happen when the machine changes network.
           let code = RemoteAddress.qrImage(for: first, side: Self.qrSide) {
            HStack {
                Spacer()
                Image(nsImage: code)
                    .interpolation(.none)
                    .accessibilityLabel(first)
                Spacer()
            }
        }
    }
}
