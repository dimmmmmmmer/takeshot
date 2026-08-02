import SwiftUI

/// "Card detected — offload?", in the takes panel.
///
/// **Why here and not a dialog.** A modal over the main window mid-shoot steals
/// the keyboard, covers the picture and has to be answered before anything else
/// can happen — over an event as ordinary as somebody plugging a reader in. This
/// sits where the offload's own status line sits, is three buttons wide, and can
/// be left unanswered for as long as the operator likes. Nothing behind it is
/// blocked and nothing has started.
///
/// It states what was found and WHY it thinks so (`CardCandidate.reasonText`) —
/// the operator is the one who knows what they plugged in, and a prompt that
/// only says "Offload?" teaches them to dismiss it unread.
struct CardOfferBanner: View {
    @EnvironmentObject private var controller: CaptureController
    /// Passed in rather than read off the controller, like `OffloadStatusStrip`
    /// takes its status line: whether this view exists at all is the caller's
    /// decision, and a view that renders nothing still takes a slot in its
    /// container's spacing.
    let card: CardCandidate

    /// Decimal GB, the unit every drive and offload tool quotes.
    static func sizeText(_ bytes: Int64) -> String {
        let gigabytes = Double(bytes) / 1_000_000_000
        guard gigabytes >= 0.1 else {
            return L("card_size_mb", Double(bytes) / 1_000_000)
        }
        return L("card_size_gb", gigabytes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OffloadChrome.tightSpacing) {
            HStack(spacing: 6) {
                Image(systemName: "sdcard")
                    .foregroundStyle(.orange)
                Text(L("card_detected", card.name))
                    .offloadText(.section)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text(L("card_contents", card.files, Self.sizeText(card.bytes)))
                .offloadText(.caption)
                .lineLimit(1)
            // The reason, always. See the type comment.
            Text(card.reasonText)
                .offloadText(.caption)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            buttons
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(OffloadChrome.cardPadding)
        .background(Color.orange.opacity(OffloadChrome.cardTintOpacity),
                    in: RoundedRectangle(cornerRadius: OffloadChrome.cardRadius))
    }

    /// Offload / Ignore / Never. Offload is the only prominent one: the other
    /// two are ways out, and a row of three equal buttons makes dismissing look
    /// like the same weight of decision as starting a copy.
    private var buttons: some View {
        HStack(spacing: OffloadChrome.rowSpacing) {
            Button(L("card_offer_offload")) { controller.acceptCardOffer() }
                .buttonStyle(.borderedProminent)
                .help(L("card_offer_offload_help"))
            Button(L("card_offer_ignore")) { controller.ignoreCardOffer() }
                .help(L("card_offer_ignore_help"))
            Button(L("card_offer_never")) { controller.neverOfferCardAgain() }
                .help(L("card_offer_never_help"))
            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .padding(.top, 2)
    }
}
