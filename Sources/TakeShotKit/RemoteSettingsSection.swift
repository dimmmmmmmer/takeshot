import SwiftUI

/// The Remote section of the settings window: the switch, the port, the code,
/// and the addresses a phone can reach the app on.
///
/// Its own file rather than another block in `SettingsView`: that view is
/// already the densest localized surface in the app and close enough to the
/// file-length ceiling that the next section would have pushed a comment out to
/// make room.
struct RemoteSettingsSection: View {
    @EnvironmentObject private var controller: CaptureController

    /// How wide the QR code is drawn. Big enough that a phone camera locks on
    /// from arm's length across a cart, small enough to leave the settings
    /// window its fixed width.
    static let qrSide: CGFloat = 132

    private var isOn: Bool { controller.settings.remoteEnabled == true }

    var body: some View {
        Section(L("settings_remote")) {
            Toggle(L("remote_enable"), isOn: Binding(
                get: { isOn },
                set: { controller.settings.remoteEnabled = $0 ? true : nil }))
            if isOn {
                portRow
                pinRow
                addressRow
                scriptRow
                multiviewRow
                Text(L("remote_hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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

    @ViewBuilder private var addressRow: some View {
        let urls = controller.remoteURLs
        LabeledContent(L("remote_address")) {
            VStack(alignment: .trailing, spacing: 4) {
                if controller.remoteBoundPort == 0 {
                    Text(L("remote_offline")).foregroundStyle(.secondary)
                } else if urls.isEmpty {
                    // No non-loopback IPv4 at all: nothing to read out, and
                    // saying so beats an empty row the operator reads as a bug.
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

    /// The script supervisor's page, one row and one QR under the operator
    /// remote's — the same addresses with the page's path on them. Shown only
    /// while there is something to scan; the offline and no-network states are
    /// already said once, in `addressRow`.
    @ViewBuilder private var scriptRow: some View {
        let urls = controller.remoteURLs.map { $0 + RemotePage.scriptPath }
        if controller.remoteBoundPort > 0, !urls.isEmpty {
            LabeledContent(L("remote_script")) {
                VStack(alignment: .trailing, spacing: 4) {
                    ForEach(urls, id: \.self) { url in
                        Text(url)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
            if let first = urls.first,
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

    /// The camera grid, one row and one QR under the script page's — the
    /// exact pattern that row set, path and all.
    @ViewBuilder private var multiviewRow: some View {
        let urls = controller.remoteURLs.map { $0 + RemotePage.multiviewPath }
        if controller.remoteBoundPort > 0, !urls.isEmpty {
            LabeledContent(L("remote_multiview")) {
                VStack(alignment: .trailing, spacing: 4) {
                    ForEach(urls, id: \.self) { url in
                        Text(url)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
            if let first = urls.first,
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
}
