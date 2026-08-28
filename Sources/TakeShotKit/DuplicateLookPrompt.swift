import AppKit
import Foundation

/// "A look of this name is already in the library — what should happen to it?",
/// in one place and behind a seam.
///
/// The only modal alert in the app (`FilePanel` covers every file dialog;
/// everything else the operator is told goes through a toast or a banner). It
/// gets the same treatment for the same reason: `NSAlert.runModal()` stops the
/// calling thread until somebody clicks, so every arm of `adoptLooks` behind it
/// was unreachable from a test — a re-import could not be driven at all, and
/// what "Replace" and "Keep Both" actually do to the folder was asserted
/// nowhere. Those three arms are file operations on the operator's look
/// library, one of which DELETES a file.
///
/// # The buttons and the answers come from one list
///
/// `NSAlert` answers with a POSITION — `.alertFirstButtonReturn` and its two
/// neighbours — so the mapping back to a choice is an index into the order the
/// buttons were added in. Written as two separate lists (three `addButton`
/// calls, then a `switch` over three response constants) that is a silent
/// hazard: inserting a button in the middle, or reordering two so the
/// destructive one is not first, leaves both halves compiling and swaps what
/// two of the three buttons DO. The operator presses "Skip" and a look is
/// overwritten.
///
/// So `order` is the single list, the alert is built from it and the response
/// is resolved through it, and the two cannot come apart. What a test can then
/// hold is the thing that used to be invisible: that the button in position N
/// of a real `NSAlert` is the one whose choice position N resolves to.
@MainActor
enum DuplicateLookPrompt {
    /// One offered answer and the button that carries it.
    struct Option {
        let choice: CaptureController.DuplicateLUTChoice
        let titleKey: String
    }

    /// The three answers, in the order their buttons appear — which is also the
    /// order `NSAlert` reports them in. Replace is first because it is the
    /// default action of the sheet; skip is last and is also what anything
    /// unrecognized falls back to (see `choice(for:)`).
    static let order: [Option] = [
        Option(choice: .replace, titleKey: "lut_replace"),
        Option(choice: .keepBoth, titleKey: "lut_keep_both"),
        Option(choice: .skip, titleKey: "lut_skip")
    ]

    /// What actually runs the alert. Replaced by the suite; never by the app.
    ///
    /// Only `runModal()` is in here — building the alert is `configured(name:)`
    /// and reading the answer is `choice(for:)`, so both halves can be asserted
    /// against a real `NSAlert` without one ever being shown. Same split, and
    /// the same reasoning, as `FilePanel.saveHandler`.
    static var handler: (String) -> CaptureController.DuplicateLUTChoice = { name in
        choice(for: configured(name: name).runModal())
    }

    /// What to do with the duplicate called `name`.
    static func ask(name: String) -> CaptureController.DuplicateLUTChoice {
        handler(name)
    }

    /// The alert for `name`, built and not shown. Building one costs nothing
    /// and shows nothing; it is `runModal()` that stops the thread.
    static func configured(name: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = L("lut_duplicate_title", name)
        alert.informativeText = L("lut_duplicate_text")
        for option in order {
            alert.addButton(withTitle: L(option.titleKey))
        }
        return alert
    }

    /// The choice a modal response names.
    ///
    /// Anything outside the three buttons is SKIP, and that is the safe
    /// default rather than an arbitrary one: an alert dismissed by any route
    /// nobody anticipated must not be read as permission to delete the look
    /// that is already in the library.
    static func choice(
        for response: NSApplication.ModalResponse
    ) -> CaptureController.DuplicateLUTChoice {
        let index = response.rawValue
            - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard order.indices.contains(index) else { return .skip }
        return order[index].choice
    }
}
