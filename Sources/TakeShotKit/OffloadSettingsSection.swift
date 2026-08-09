import SwiftUI

/// The Offload section of the settings window: whether a mounted card is
/// offered at all.
///
/// The cards already dealt with used to be here too, as a count and a "forget
/// all" button. They are a named, per-row list on the offload sheet now (owner
/// item 18) — a count answers neither "which cards" nor "this one, please", and
/// the sheet is where the operator is already asking what has been copied.
///
/// Its own file rather than another block in `SettingsView`, for the reason
/// `RemoteSettingsSection` is: that view is the densest localized surface in the
/// app and close enough to the file-length ceiling that the next section would
/// push a comment out to make room.
struct OffloadSettingsSection: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        Section(L("settings_offload")) {
            Toggle(L("offer_mounted_cards"), isOn: Binding(
                // nil is on: the default is stored as absent so a settings blob
                // written by an older build still means what it meant.
                get: { controller.offersMountedCards },
                set: { controller.settings.offload.offerMountedCards = $0 ? nil : false }))
            Text(L("offer_mounted_cards_hint"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
