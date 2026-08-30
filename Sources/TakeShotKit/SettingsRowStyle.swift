import SwiftUI

/// How every settings row lines its label up with its control.
///
/// `LabeledContent`'s default puts the label on the FIRST TEXT BASELINE of the
/// content. That is right when the two are the same height and wrong the moment
/// the content is taller than one line — a number field with a stepper beside
/// it, a stack of addresses, a picker over a hint — because the label then sits
/// at the top of a control that is centred, and the row reads as broken
/// (owner: "у нас наименование прибито к верху а значение цифровое и его
/// перключатель центрованы. странно выглядит", and the same complaint about the
/// remote's address list).
///
/// A style rather than an alignment argument at each row: there are dozens of
/// them across nine settings sections, and a row that forgot the argument is
/// exactly the drift this codebase keeps finding. Applied once at the settings
/// root, it reaches every `LabeledContent` under it — including the ones a
/// later section adds without knowing this exists.
struct SettingsRowStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 8) {
            configuration.label
            Spacer(minLength: 8)
            configuration.content
        }
    }
}

extension View {
    /// Every settings row centres its label against its control.
    func settingsRowAlignment() -> some View {
        labeledContentStyle(SettingsRowStyle())
    }
}
