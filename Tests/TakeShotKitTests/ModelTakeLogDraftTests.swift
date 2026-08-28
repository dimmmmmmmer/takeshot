import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// The take log popover's draft: what it opens with, what it saves, and the
/// fact that those are the same thing.
///
/// The popover is the app's only way to correct what a take was slated as, and
/// the correction lands on the take list, `takeshot-slate.csv` and the ALE —
/// never on the recorded file (`CaptureController+Slate` says why at length).
/// The sidecar is therefore the NEWER of the two by construction, and the
/// library restore reads it back that way, so a slate changed by a save nobody
/// meant travels into the next session as the truth.
///
/// Neither half could be asked anything before: both were private methods of a
/// view, over five `@State` strings, inside a body SwiftUI does not build until
/// the popover is presented.
@Suite struct ModelTakeLogDraftTests {
    private func take(scene: String = "", shot: String = "", number: Int = 0,
                      comment: String = "", description: String = "") -> Take {
        var take = Take(url: URL(fileURLWithPath: "/tmp/takeshot-draft/A001C001.mov"),
                        scene: "", roll: "001", takeNumber: 4,
                        startTimecode: nil, durationSeconds: 3,
                        recordedAt: Date())
        take.slate = SlateMetadata(scene: scene, shot: shot, take: number)
        take.comment = comment
        take.logDescription = description
        return take
    }

    /// Open the log and save it without typing: the take is exactly as it was.
    ///
    /// This is the whole contract, and the take-number field really did break
    /// it — the load showed `SlateMetadata.take` as text and the save kept the
    /// first four DIGITS of that text, so any take past 9999 came back as a
    /// different take on a save the operator did not think they had made. The
    /// two halves read the same rule now (`SlateTakeField`).
    @Test func openingTheLogAndSavingItChangesNothing() {
        let takes: [Take] = [
            take(),
            take(scene: "12A", shot: "B", number: 3),
            take(scene: "104", shot: "", number: 1, comment: "boom in frame"),
            take(scene: "", shot: "", number: 0, description: "wide, no slate"),
            take(scene: "7", shot: "C", number: SlateTakeField.maximum,
                 comment: "circle", description: "insert"),
        ]
        for original in takes {
            let draft = TakeLogDraft(of: original)
            #expect(draft.slate == original.slate,
                    "the slate came back as \(draft.slate) from \(original.slate)")
            #expect(draft.comment == original.comment)
            #expect(draft.logDescription == original.logDescription)
        }
    }

    /// A take number the field cannot hold does not survive the round trip, and
    /// that is the honest answer rather than a gap: `SlateTakeField.maximum` is
    /// what every TAKE field in the app accepts, so a larger number can only
    /// have arrived from an older saved sidecar. Saving it back clamps it —
    /// visibly, to the ceiling, rather than to a plausible-looking number four
    /// digits long.
    @Test func aTakeNumberPastTheCeilingComesBackAsTheCeiling() {
        let draft = TakeLogDraft(of: take(scene: "9", number: 12345))
        #expect(draft.takeText == "12345", "the field did not show what was stored")
        #expect(draft.slate.take == SlateTakeField.maximum)
    }

    /// What fills the speech-bubble button in the takes panel is the same four
    /// fields the popover opens with, so a filled button never opens an empty
    /// editor and a hollow one never opens a full one. Each field on its own is
    /// enough — a take logged with nothing but a description is a logged take.
    @Test func theButtonIsFilledExactlyWhenTheEditorHasSomethingInIt() {
        #expect(TakeLogDraft(of: take()).isEmpty)
        #expect(TakeLogDraft().isEmpty)
        let filled: [Take] = [
            take(scene: "12"),
            take(shot: "B"),
            take(number: 1),
            take(comment: "boom"),
            take(description: "wide"),
        ]
        for take in filled {
            let fields: String = "\(take.slate) / \(take.comment)"
                + " / \(take.logDescription)"
            #expect(!TakeLogDraft(of: take).isEmpty,
                    "\(fields) read as an empty log")
        }
        // a stored take number of 0 is "not logged" and must not fill it: the
        // field shows blank for it, so a filled button would open on nothing
        #expect(TakeLogDraft(of: take(number: 0)).isEmpty)
    }

    /// The save, through the controller that files it. Two calls, and the take
    /// list carries what the fields said afterwards.
    @Test @MainActor func savingTheDraftFilesEveryFieldOnTheTake() async throws {
        try await ControllerHarness.run { controller, root in
            let take = ControllerFixtures.take(named: "A001C001", in: root)
            try ControllerFixtures.placeholder(for: take)
            controller.takes = [take]

            var draft = TakeLogDraft(of: take)
            draft.scene = "12A"
            draft.shot = "B"
            draft.takeText = "3"
            draft.comment = "boom in frame"
            draft.logDescription = "wide"
            controller.setComment(draft.comment, for: take)
            controller.setSlate(draft.slate, description: draft.logDescription,
                                for: take)

            let saved = try #require(controller.takes.first)
            #expect(saved.slate == SlateMetadata(scene: "12A", shot: "B", take: 3))
            #expect(saved.comment == "boom in frame")
            #expect(saved.logDescription == "wide")
            // and re-opening the log on the saved take shows what was typed
            #expect(TakeLogDraft(of: saved) == draft)
        }
    }
}
