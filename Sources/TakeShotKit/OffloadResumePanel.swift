import CaptureCore
import SwiftUI

/// The question a resumable destination raises, and the two answers.
///
/// **Why it is a question at all.** `OffloadEngine`'s own comment says a skipped
/// folder is how footage disappears between a wiped card and a delivery. Resume
/// exists to skip files, so it owes that rule more than anything else in the
/// app: the operator is told which disk holds how much of this card, how that
/// was established, what re-checking it will cost, and gets a button that copies
/// the whole card anyway.
///
/// It sits in the sheet rather than in an alert so it is reachable from a test
/// and so the numbers can be read next to the destination list they are about.
struct OffloadResumePanel: View {
    let review: OffloadResumeReview
    let resume: () -> Void
    let copyEverything: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: OffloadChrome.rowSpacing) {
            Label(L("offload_resume_title"),
                  systemImage: "arrow.clockwise.circle.fill")
                .offloadText(.section, tint: .accentColor)
            ForEach(review.offers) { offer in
                Text(Self.line(offer, card: review.card))
                    .offloadText(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // What the gate is, stated before the button that acts on it: this
            // is the sentence that makes "already there" mean something.
            Text(L("offload_resume_gate"))
                .offloadText(.caption)
                .fixedSize(horizontal: false, vertical: true)
            // …and what it costs, because it is a trade and not a free win.
            Text(L("offload_resume_cost"))
                .offloadText(.caption)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(L("offload_resume_accept", review.bestCase),
                       action: resume)
                    .keyboardShortcut(.defaultAction)
                Button(L("offload_resume_decline"), action: copyEverything)
            }
        }
        .padding(OffloadChrome.cardPadding)
        .background(Color.accentColor.opacity(OffloadChrome.cardTintOpacity),
                    in: RoundedRectangle(cornerRadius: OffloadChrome.cardRadius))
    }

    /// One destination's line: what it holds, or why it holds nothing this run
    /// can use. Never just "everything will be copied" — an operator who is not
    /// told why stops believing the count on the disks that DO offer one.
    static func line(_ offer: OffloadResumeOffer, card: OffloadVolume) -> String {
        let name = offer.destination.lastPathComponent
        guard let refusal = offer.refusal else {
            guard offer.isUsable else {
                return L("offload_resume_dest_nothing", name)
            }
            return L("offload_resume_dest", name, offer.files, card.files,
                     OffloadFormat.shortBytes(offer.bytes))
        }
        return L("offload_resume_dest_full", name, Self.text(refusal))
    }

    /// The engine's refusals in the operator's language.
    ///
    /// Mapped here rather than shown as they arrive, for the reason
    /// `CaptureController.verifyFailureMessage` maps its own: CaptureCore states
    /// these in English because they go into a report for post, and every one of
    /// them is something the operator can act on now.
    static func text(_ refusal: OffloadResumeRefusal) -> String {
        switch refusal {
        case .noManifest:
            return L("offload_resume_why_new")
        case .noStamp:
            return L("offload_resume_why_unstamped")
        case .differentCard:
            return L("offload_resume_why_other_card")
        case .cardChanged:
            return L("offload_resume_why_card_changed")
        case .differentHash(let found):
            return L("offload_resume_why_other_hash", found.displayName)
        case .unreadable(let reason):
            return L("offload_resume_why_unreadable", reason)
        }
    }
}
