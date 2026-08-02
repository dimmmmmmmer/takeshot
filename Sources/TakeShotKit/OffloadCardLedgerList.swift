import SwiftUI

/// The cards the app has stopped asking about, under the offload history
/// (owner item 18).
///
/// **Why it has to be visible.** The ledger is the only piece of this feature
/// that acts by NOT doing something: a card that was offloaded, or answered with
/// Never, silently never raises its prompt again. Invisible bookkeeping that
/// suppresses a prompt is indistinguishable from a broken prompt, and the
/// operator's next move is to stop trusting the offer at all. So every entry is
/// listed with what put it there and when, and every row can be cleared.
///
/// **Why here and not in Settings.** It used to be a count and a "clear all"
/// button in the Offload settings section, which answers neither "which cards"
/// nor "this one, please". This sheet is where the question is asked — it is
/// already the place the operator comes to ask what has been copied — and one
/// list of remembered cards beats a count in one window and the cards
/// themselves nowhere.
///
/// **Why it disappears when empty**, where the history above it keeps its
/// heading: this is the last block on the sheet, so nothing moves under it, and
/// nobody comes looking for it except when a card they expected to be asked
/// about was not — which means it is not empty.
struct OffloadCardLedgerList: View {
    @ObservedObject var ledger: OffloadedCardLedger
    @EnvironmentObject private var controller: CaptureController

    /// Local, and short/short like the history's: these rows are scanned, not
    /// read.
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    /// Newest first, like the history. The ledger appends, and a card dealt
    /// with this morning is the one being asked about now.
    private var rows: [OffloadedCardRecord] {
        ledger.cards.sorted { $0.date > $1.date }
    }

    var body: some View {
        if !ledger.cards.isEmpty {
            VStack(alignment: .leading, spacing: OffloadChrome.rowSpacing) {
                Text(L("cards_remembered"))
                    .offloadText(.section)
                ForEach(rows) { card in
                    row(card)
                }
            }
        }
    }

    private func row(_ card: OffloadedCardRecord) -> some View {
        HStack(spacing: OffloadChrome.rowSpacing) {
            Image(systemName: Self.symbol(card))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(card.name)
                    .offloadText(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(Self.detail(card))
                    .offloadText(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                controller.forgetOffloadedCard(card.key)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help(L("cards_forget"))
        }
    }

    // MARK: - what a row says

    /// When, and which of the two decisions this was. The two are not
    /// interchangeable: a copied card comes back the moment it has been shot on
    /// again, a silenced one never does.
    static func detail(_ card: OffloadedCardRecord) -> String {
        let kind = card.suppressed ? "cards_kind_never" : "cards_kind_offloaded"
        return "\(formatter.string(from: card.date)) · \(L(kind))"
    }

    static func symbol(_ card: OffloadedCardRecord) -> String {
        card.suppressed ? "bell.slash" : "checkmark.seal"
    }
}
