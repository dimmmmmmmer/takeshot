import SwiftUI

/// The Offload section of the settings window: whether a mounted card is offered
/// at all, and the way back from a "Never".
///
/// Its own file rather than another block in `SettingsView`, for the reason
/// `RemoteSettingsSection` is: that view is the densest localized surface in the
/// app and close enough to the file-length ceiling that the next section would
/// push a comment out to make room.
struct OffloadSettingsSection: View {
    @EnvironmentObject private var controller: CaptureController
    @ObservedObject var ledger: OffloadedCardLedger

    var body: some View {
        Section(L("settings_offload")) {
            Toggle(L("offer_mounted_cards"), isOn: Binding(
                // nil is on: the default is stored as absent so a settings blob
                // written by an older build still means what it meant.
                get: { controller.offersMountedCards },
                set: { controller.settings.offerMountedCards = $0 ? nil : false }))
            Text(L("offer_mounted_cards_hint"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LabeledContent(L("cards_remembered")) {
                HStack {
                    Text("\(ledger.cards.count)")
                        .foregroundStyle(.secondary)
                    Button(L("cards_forget")) { ledger.clear() }
                        .disabled(ledger.cards.isEmpty)
                }
            }
            Text(L("cards_remembered_hint"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
