import SwiftUI

/// The Remote section of the settings window: the switch, the port, the code,
/// and the address a phone can reach one of the four pages on.
///
/// Its own file rather than another block in `SettingsView`: that view is
/// already the densest localized surface in the app and close enough to the
/// file-length ceiling that the next section would have pushed a comment out to
/// make room.
///
/// One link row, whatever the page count. Each page used to get its own row and
/// its own QR code, which made this section taller than the settings window on a
/// laptop screen — and all but one of the codes was always the wrong one to
/// scan. The page is picked with a segmented switch (the idiom the exposure tool
/// and the rec/playback control already use) and the row below it follows, so a
/// page added later costs a segment rather than a section.
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

    /// Which of the machine's addresses is the one being handed out — the one
    /// the code encodes and the one a click last copied.
    ///
    /// An INDEX and not the string, so switching the page carries the choice
    /// with it: the list is the same interfaces in the same order for all
    /// three pages, only the path differs, and a DIT who picked the wired
    /// address for `/cameras` has picked it for `/script` too. Out of range
    /// after a network change falls back to the first, which is the address a
    /// phone on the set network would use.
    @State private var chosen = 0

    private var isOn: Bool { controller.settings.remote.enabled == true }

    var body: some View {
        Section(L("settings_remote")) {
            Toggle(L("remote_enable"), isOn: Binding(
                get: { isOn },
                set: { controller.settings.remote.enabled = $0 ? true : nil }))
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
                get: { controller.settings.remote.portEffective },
                // Below 1024 needs root and above 65535 does not exist; a typo
                // either way would take the listener down with an error the
                // operator cannot act on.
                set: { controller.settings.remote.port = min(65535, max(1024, $0)) }),
                format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 76)
        }
    }

    private var pinRow: some View {
        LabeledContent(L("remote_pin")) {
            HStack(spacing: 10) {
                Text(controller.settings.remote.pin ?? "----")
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

    /// Which line is the one being handed out, given what was picked and what
    /// the machine is on NOW.
    ///
    /// A dock unplugged mid-shift shortens the list under a choice already
    /// made, and the fallback has to be the first address rather than an empty
    /// row or a crash — the first is the one a phone on the set network would
    /// use, which is what the operator wanted before they picked anything.
    static func picked(_ chosen: Int, of count: Int) -> Int {
        (0..<count).contains(chosen) ? chosen : 0
    }

    /// The addresses for the chosen page, and a code for the one being handed
    /// out.
    ///
    /// The addresses are the machine's own, filtered and ordered by
    /// `RemoteAddress` — loopback, link-local, tunnels and virtual bridges
    /// never appear, and the one a phone on the set network would use is
    /// first.
    @ViewBuilder private var addressRow: some View {
        let urls = controller.remoteURLs(for: link)
        let picked = Self.picked(chosen, of: urls.count)
        LabeledContent(L("remote_address")) {
            VStack(alignment: .trailing, spacing: 4) {
                if controller.remoteBoundPort == 0 {
                    Text(L("remote_not_listening")).foregroundStyle(.secondary)
                } else if urls.isEmpty {
                    // No usable IPv4 at all: nothing to read out, and saying so
                    // beats an empty row the operator reads as a bug.
                    Text(L("remote_no_network")).foregroundStyle(.secondary)
                } else {
                    ForEach(urls.indices, id: \.self) { index in
                        addressButton(urls[index], index: index,
                                      picked: index == picked)
                    }
                }
            }
        }
        if controller.remoteBoundPort > 0, urls.indices.contains(picked) {
            qrRow(for: urls[picked])
        }
    }

    /// One address, as something to hand over rather than to read out.
    ///
    /// **The click copies.** The Mac is not the device that needs this
    /// address — the phone is, and the way it gets there is a message to the
    /// director or a line in the unit's chat. Opening the page in the Mac's own
    /// browser answers a question nobody on set has (the app IS the picture),
    /// so it is here, under the secondary click, rather than in the way.
    ///
    /// The same click also points the code below at this line. It is one
    /// decision — "this is the address I am giving out" — and a laptop on the
    /// venue's Wi-Fi and the video village's router has to be able to give out
    /// either: the director on Wi-Fi and the DIT on the wired net cannot use
    /// the same one.
    private func addressButton(_ url: String, index: Int,
                               picked: Bool) -> some View {
        Button {
            chosen = index
            RemoteHandout.copy(url)
        } label: {
            HStack(spacing: 6) {
                Text(url).font(.system(.body, design: .monospaced))
                // Which line the code belongs to, said with the code's own
                // glyph instead of a sentence. Hidden from VoiceOver: the QR
                // below carries the address as its label already.
                Image(systemName: "qrcode")
                    .opacity(picked ? 1 : 0)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.link)
        .help(L("remote_address_copy"))
        .contextMenu {
            Button(L("remote_address_copy")) {
                chosen = index
                RemoteHandout.copy(url)
            }
            Button(L("remote_address_open")) { RemoteHandout.open(url) }
        }
    }

    /// The code for the address being handed out.
    ///
    /// Regenerated per render rather than cached: a QR of a 30-character URL
    /// is about a millisecond, and the settings pane is not a hot path — a
    /// cache here would be a stale-address bug waiting to happen when the
    /// machine changes network.
    @ViewBuilder private func qrRow(for url: String) -> some View {
        if let code = RemoteAddress.qrImage(for: url, side: Self.qrSide) {
            HStack {
                Spacer()
                Image(nsImage: code)
                    .interpolation(.none)
                    .accessibilityLabel(url)
                Spacer()
            }
        }
    }
}
