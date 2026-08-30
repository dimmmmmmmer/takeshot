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
            // **Trailing, and the TEXT inside it trailing too.** A grouped
            // `Form` builds its labelled controls through `LabeledContent`, so
            // this style reaches a bare `TextField` row as well — and the first
            // version dropped what the default was doing for those, which put
            // the project name's caret on the left (owner: "в настройках
            // название проекта почему-то теперь вбивается с левой стороны а не
            // с правой как раньше"). Fixing the vertical alignment must not
            // cost the horizontal one.
            //
            // NO frame around it. `frame(alignment:)` with no width proposes
            // nil to the child, and a bordered `TextField`'s ideal width grows
            // with its content — so the SRT address field stretched as it was
            // typed into and shoved the row about (owner: "интерфейс улетает
            // при вбивании адреса, растягивает поле ввода"). The `Spacer`
            // above is what puts the content on the right; each control keeps
            // whatever width it declares for itself.
            configuration.content
                .multilineTextAlignment(.trailing)
        }
    }
}

extension View {
    /// Every settings row centres its label against its control.
    func settingsRowAlignment() -> some View {
        labeledContentStyle(SettingsRowStyle())
    }
}
