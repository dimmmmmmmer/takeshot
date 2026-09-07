import CaptureCore
import SwiftUI

/// What the two pickers offer, and what counts as something they do not.
///
/// A table rather than literal rows in the pickers, because the typed-value
/// entry has to know what a preset IS: an aspect that already has a row must
/// not get a second one spelling the same thing.
enum AssistPresets {
    /// The aspects most shows are shot in.
    static let frameline: [(label: String, value: Double)] = [
        ("1.85", 1.85), ("2.00", 2.0), ("2.35", 2.35), ("2.39", 2.39),
        ("4:3", 4.0 / 3.0), ("9:16", 9.0 / 16.0),
    ]
    /// The squeeze factors most anamorphics have.
    static let desqueeze: [(label: String, value: Double)] = [
        ("1x", 1.0), ("1.33x", 1.33), ("1.5x", 1.5), ("1.8x", 1.8), ("2x", 2.0),
    ]

    /// `value` when it is a typed one — off, or a preset, is nil.
    ///
    /// Compared with a tolerance because the presets are not all exact: 4:3 is
    /// 1.3333333333333333 as a Double, and an operator who types "4:3" into the
    /// box must land ON the preset row rather than beside it, with a second row
    /// spelling the same aspect a ten-thousandth away from the first.
    static func custom(_ value: Double?,
                       among presets: [(label: String, value: Double)]) -> Double? {
        guard let value, value > 0 else { return nil }
        return presets.contains { abs($0.value - value) < 0.0005 } ? nil : value
    }
}

/// The "and anything else" half of a preset picker.
///
/// The frameline and the desqueeze both got one, for the same reason and in the
/// same shape: their pickers list the aspects and squeeze factors most shows
/// are shot in, and a show that is not one of them had no way in at all
/// (owner: "desqueze хочу иметь варик писать кастом", "и кастом фреймлайнс
/// тоже").
///
/// The field follows the picker rather than competing with it: picking a preset
/// rewrites what is in the box, so the two never state different numbers. A
/// value that cannot be used snaps back — see `AssistRatioInput.parse`.
struct AssistCustomField: View {
    let label: String
    let range: ClosedRange<Double>
    /// What the control is set to now; nil — off, which leaves the box empty.
    let value: Double?
    let apply: (Double) -> Void

    @State private var text = ""
    @FocusState private var editing: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            TextField("", text: $text)
                .font(.caption.monospacedDigit())
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
                .controlSize(.mini)
                .frame(width: 64)
                .focused($editing)
                .onSubmit(commit)
                // committing on the way out as well as on Return: an operator
                // who types a number and clicks back onto the picture means it
                // (same shape as the chroma key's hex field, for the same
                // reasons — see `ChromaColorField`)
                .onChange(of: editing) { _, focused in
                    if !focused { commit() }
                }
        }
        .onAppear { text = Self.text(for: value) }
        // the picker moved it: the box says what the control says. Never while
        // it is being typed in — that would fight the operator's cursor.
        .onChange(of: value) { _, moved in
            if !editing { text = Self.text(for: moved) }
        }
    }

    private func commit() {
        let outcome = Self.committed(text: text, current: value, in: range)
        if let accepted = outcome.value { apply(accepted) }
        text = outcome.text
    }

    /// What pressing Return does: the value to apply — nil, nothing changes —
    /// and what the box says afterwards.
    ///
    /// Static and pure, like the chroma key's `committed` beside it and for the
    /// same reason: the interesting half of a field is what it does with what
    /// was typed, and that half is unreachable through a view. Two things it
    /// pins that are easy to get subtly wrong —
    ///
    /// - a refusal SNAPS BACK. The box that keeps a rejected "0" on screen
    ///   looks accepted, and the operator walks away believing the frameline is
    ///   set to something the app quietly ignored.
    /// - an accepted value is rewritten from the NUMBER, not left as typed. So
    ///   "16/9" and " 2,39 " settle into what the picker's row would say, and
    ///   the box and the picker cannot end up spelling one value two ways.
    static func committed(text: String, current: Double?,
                          in range: ClosedRange<Double>)
        -> (value: Double?, text: String) {
        guard let parsed = AssistRatioInput.parse(text, in: range) else {
            return (nil, self.text(for: current))
        }
        return (parsed, AssistRatioInput.text(parsed))
    }

    /// What the box shows for a control that is off — nothing, rather than a
    /// number that is not being drawn.
    static func text(for value: Double?) -> String {
        guard let value, value > 0 else { return "" }
        return AssistRatioInput.text(value)
    }
}
