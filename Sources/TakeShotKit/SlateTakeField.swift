import Foundation

/// What a TAKE field means, in both directions: the text an operator types
/// becomes a take number, and a take number becomes the text the field shows.
///
/// `SlateStep` is the other half of the same field — what the ‹ › arrows do to
/// it. This is what the KEYBOARD does to it, and the two have to land on the
/// same values or the two ways of setting one number disagree.
///
/// # Why this is one place and was three
///
/// The same TAKE field is reachable from three surfaces, and all three write
/// the same `SlateMetadata.take` — which goes into the .mov's metadata at
/// `TakeWriter` time, and into `takeshot-slate.csv` and the ALE afterwards. The
/// three parsed it differently, and the disagreement was invisible because
/// `SlateFieldsEditor` draws two of the three, so the CONTROL looked shared:
///
/// | typed | footer field | takes-panel popover | the phone |
/// | --- | --- | --- | --- |
/// | `12` | 12 | 12 | 12 |
/// | `12A` | 12 | 12 | **0 — nothing logged** |
/// | `12345` | **9999** | **1234** | **12345** |
/// | `0` | **1** | 0 | 0 |
///
/// A scripty typing a take number on a phone and the operator typing it into
/// the footer are the same person logging the same take, and the row that
/// reaches editorial should not depend on which one of them got to it. The
/// `12345` row is the one that costs something: 1234 is a plausible take number
/// and nothing on screen says the other digit went.
///
/// # The answers, and why these
///
/// - **Non-digits are dropped, not rejected.** `12A` is a scene, not a take
///   (`slate_take_help`: "Take number inside the scene"), and two of the three
///   surfaces already read it as 12 — as does the CLIP field next door
///   (`commitClipText`). The phone rejecting the whole entry was the outlier,
///   and it fails silently: the field goes blank and the take is logged with no
///   number at all.
/// - **Over the ceiling CLAMPS rather than truncating.** `SlateStep` already
///   clamps when the ‹ › arrows page up (`min(maxNumber, next)`), so clamping
///   here is what makes the arrows and the keyboard one control. Truncating to
///   four digits was the popover's answer and it is silent data loss that looks
///   like success.
/// - **Nothing, or nothing but zeros, is 0** — not logged. That is the value
///   `SlateMetadata.isEmpty`, `summary` and `compact` all test with `take > 0`,
///   and the state `SlateStep` reaches by paging DOWN off 1. Reading a typed
///   `0` as take 1, which the footer did, invented a take the operator did not
///   ask for.
enum SlateTakeField {
    /// The highest take number the field will hold, and deliberately the same
    /// number the arrows stop at: `SlateStep.maxNumber` says "nothing pages
    /// past this", and a field that ACCEPTED more would make that sentence
    /// false from the keyboard. It was three separate `9999` literals before —
    /// here, in `commitSlateTakeText` and in `advanceSlateTake`.
    static let maximum = SlateStep.maxNumber

    /// The take number `text` names, or 0 when it names none.
    ///
    /// ASCII digits, which is the predicate `SlateStep` already pages on and
    /// deliberately not `Character.isNumber`: that one is true of "١٢" and
    /// every other Unicode digit, and `Int(_:)` then refuses the string it was
    /// handed — so a plain `filter(\.isNumber)` turns a non-Latin numeral into
    /// whatever the call site's `?? fallback` happens to be.
    static func number(from text: String) -> Int {
        let digits = text.filter { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty else { return 0 }
        // A run of digits too long to be an Int is over the ceiling by a very
        // long way. `Int(_:)` answers nil for it, and reading that as "no
        // number" would log a leant-on keyboard as an unslated take.
        guard let value = Int(digits) else { return maximum }
        return min(maximum, value)
    }

    /// What the field shows for a take number. An unlogged take is an EMPTY
    /// field, never a `0`: blank is how the operator sees that numbering is
    /// still following the clip counter, and it is what the exporters put in
    /// the Take column for the same reason.
    static func text(for number: Int) -> String {
        number > 0 ? String(number) : ""
    }
}
