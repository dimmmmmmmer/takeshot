import CaptureCore
import Foundation

/// What the take log popover is holding while it is open: the take's slate, its
/// description and its comment, as text the operator is editing.
///
/// # Why a value, and not five `@State` strings
///
/// The popover is the app's only way to correct what a take was slated as, and
/// a correction has to be one. Its two halves — load the take into the fields,
/// save the fields back onto the take — are exact inverses or they are a
/// rewrite: an operator who opens the log to fix a typo in the comment, and
/// presses save, must not change the scene, the shot or the take number by
/// having touched none of them.
///
/// Nothing could ask whether they were inverses. Both halves lived as private
/// methods on the view, over five `@State` strings, inside a body SwiftUI does
/// not build until the popover is presented — and the take-number half was
/// NOT an inverse (see `SlateTakeField`). The correction it writes goes to the
/// take list, `takeshot-slate.csv` and the ALE, and the sidecar is what the
/// library restore reads back as the newer of the two, so a slate changed by a
/// save nobody meant travels into the next session as the truth.
///
/// Stated as a value, the round trip is one assertion.
struct TakeLogDraft: Equatable {
    var comment: String = ""
    var scene: String = ""
    var shot: String = ""
    /// The take number as TYPED. Text rather than Int so an emptied field can
    /// mean "not logged" — see `SlateFieldsEditor.takeText`.
    var takeText: String = ""
    var logDescription: String = ""

    /// An empty draft. What the view's `@State` holds before a row's button has
    /// ever been pressed — the popover loads the take it belongs to on the way
    /// open, so this value is never edited or saved.
    init() {}

    /// The draft the popover opens with.
    init(of take: Take) {
        comment = take.comment
        scene = take.slate.scene
        shot = take.slate.shotText
        takeText = SlateTakeField.text(for: take.slate.take)
        logDescription = take.logDescription
    }

    /// What the fields say, as a slate. The take number is read the way every
    /// other TAKE field in the app is read.
    var slate: SlateMetadata {
        SlateMetadata(scene: scene,
                      shot: SlateTakeField.number(from: shot),
                      take: SlateTakeField.number(from: takeText))
    }

    /// Whether the log holds anything at all — which is what fills the
    /// speech-bubble button in the takes panel, so a glance down the panel
    /// finds the logged takes.
    ///
    /// The same four fields the popover edits, and deliberately not
    /// `TakeLogExporter.hasSlateRow`: that one decides whether a take earns a
    /// row in the SLATE sidecar and excludes the comment, which has a column of
    /// its own in the log. A filled button that opens an empty editor is the
    /// failure this rules out.
    var isEmpty: Bool {
        comment.isEmpty && scene.isEmpty && shot.isEmpty
            && logDescription.isEmpty && slate.take <= 0
    }
}
