import AppKit
import CaptureCore
import SwiftUI

/// A naming field that refuses an invalid character instead of erasing it
/// afterwards (owner item 28).
///
/// Why this is an `NSTextField` and not a SwiftUI `TextField` with a filtering
/// binding. A binding filters after the fact: SwiftUI writes the typed string
/// through, the setter cleans it, and the field is re-read on the next update —
/// so the character appears and then vanishes, which is exactly the behaviour
/// that was reported. AppKit has the mechanism for doing it properly and
/// SwiftUI has none: an `NSCell` asks its formatter whether a PARTIAL edit is
/// valid before installing it, so a formatter that answers "no, use this
/// instead" replaces the edit in the same keystroke and the refused character
/// is never drawn.
///
/// Styled to match `.textFieldStyle(.roundedBorder)`, which is what the rest of
/// the naming row wears — the footer's width budget is measured to the point
/// and a field of a different height would reflow the whole bar.
struct NameTextField: NSViewRepresentable {
    /// Which field's rules apply (see `NameField`).
    let field: NameField
    @Binding var text: String
    /// Digits that do not jump around as they change — the counters use it.
    var monospacedDigit = false
    /// Enter, or focus leaving the field. Where a field has a commit step
    /// (the clip number sets the filename padding from what was typed), this
    /// is it; the binding itself updates on every accepted keystroke.
    var onCommit: () -> Void = {}
    /// The operator started or stopped typing in this field. Only the clip
    /// counter needs it: the number moves on its own when a take lands, and a
    /// field that mirrored that mid-word would take the edit away.
    var onEditingChanged: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> NSTextField {
        let view = NSTextField(string: field.normalized(text))
        view.formatter = context.coordinator.formatter
        view.delegate = context.coordinator
        view.target = context.coordinator
        view.action = #selector(Coordinator.submitted(_:))
        view.isBezeled = true
        view.bezelStyle = .roundedBezel
        view.isEditable = true
        view.isSelectable = true
        view.usesSingleLineMode = true
        view.lineBreakMode = .byClipping
        view.cell?.wraps = false
        view.cell?.isScrollable = true
        if monospacedDigit {
            view.font = NSFont.monospacedDigitSystemFont(
                ofSize: NSFont.systemFontSize, weight: .regular)
        }
        // the horizontal size comes from the caller's .frame(width:); without
        // this the field also refuses to be squeezed by the footer
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow,
                                                     for: .horizontal)
        return view
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.owner = self
        // Only when the model really differs: assigning stringValue while the
        // operator is mid-word resets the insertion point to the end.
        let wanted = field.normalized(text)
        if nsView.stringValue != wanted { nsView.stringValue = wanted }
    }

    /// The height is the control's own; the width is whatever was proposed, so
    /// a `.frame(width:)` around this behaves like it does around a `TextField`.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField,
                      context: Context) -> CGSize? {
        let intrinsic = nsView.intrinsicContentSize
        return CGSize(width: proposal.width ?? intrinsic.width,
                      height: intrinsic.height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(owner: self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var owner: NameTextField
        let formatter: NameFieldFormatter

        init(owner: NameTextField) {
            self.owner = owner
            formatter = NameFieldFormatter(field: owner.field)
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            owner.onEditingChanged(true)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            owner.text = field.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            owner.text = field.stringValue
            owner.onEditingChanged(false)
            owner.onCommit()
        }

        @objc func submitted(_ sender: NSTextField) {
            owner.text = sender.stringValue
            owner.onCommit()
        }
    }
}

/// The formatter behind `NameTextField`: it holds a `String` and vets every
/// partial edit against the field's rules.
///
/// Returning `false` with a replacement in `partialStringPtr` is the contract
/// AppKit documents for "not that, this" — the field installs the replacement
/// and the rejected text is never displayed. Returning false with the string
/// untouched would beep and drop the edit entirely, which is wrong for the two
/// fields that TRANSFORM rather than refuse (a lowercase camera label becomes
/// uppercase; it is not an error).
final class NameFieldFormatter: Formatter {
    private let field: NameField

    init(field: NameField) {
        self.field = field
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not created from a nib") }

    override func string(for obj: Any?) -> String? {
        obj as? String ?? ""
    }

    override func getObjectValue(
        _ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?,
        for string: String,
        errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        obj?.pointee = field.normalized(string) as NSString
        return true
    }

    override func isPartialStringValid(
        _ partialStringPtr: AutoreleasingUnsafeMutablePointer<NSString>,
        proposedSelectedRange proposedSelRangePtr: NSRangePointer?,
        originalString: String,
        originalSelectedRange: NSRange,
        errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        let proposed = partialStringPtr.pointee as String
        let cleaned = field.normalized(proposed)
        guard cleaned != proposed else { return true }
        partialStringPtr.pointee = cleaned as NSString
        // Put the caret where the accepted text ends rather than letting AppKit
        // park it at 0: typing a refused character in the middle of a roll name
        // must not send the cursor back to the start of it.
        if let proposedSelRangePtr {
            let dropped = (proposed as NSString).length
                - (cleaned as NSString).length
            let location = max(0, min((cleaned as NSString).length,
                                      proposedSelRangePtr.pointee.location - dropped))
            proposedSelRangePtr.pointee = NSRange(location: location, length: 0)
        }
        return false
    }
}
