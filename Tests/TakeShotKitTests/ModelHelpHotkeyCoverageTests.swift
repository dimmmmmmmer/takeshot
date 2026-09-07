import Foundation
import Testing

@testable import TakeShotKit

/// **Every key the app ships with is in the manual, in both languages.**
///
/// The manual's Keyboard section is where an operator looks for a key they
/// half-remember, and a key that is not in it is a feature nobody finds. It is
/// also the one part of the documentation that goes stale silently: adding an
/// action to `HotkeyAction` gives it a button, a menu item and a working chord
/// without anything asking whether the manual heard about it — which is
/// exactly how the clean feed's ⌃U shipped in a build whose manual did not
/// mention it.
@Suite struct ModelHelpHotkeyCoverageTests {
    private func manual(_ language: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TakeShotKit/Resources")
        return try String(
            contentsOf: root.appendingPathComponent("\(language).lproj/Help.md"),
            encoding: .utf8)
    }

    /// Matched on the chord as the app DISPLAYS it, wrapped in the backticks
    /// the manual sets keys in — "M" alone would be found in any sentence with
    /// a capital M in it, and would prove nothing.
    @Test func everyDefaultChordIsInTheManualInBothLanguages() throws {
        for language in ["en", "ru"] {
            let text = try manual(language)
            for action in HotkeyAction.allCases {
                let chord = action.defaultCombo.display
                #expect(text.contains("`\(chord)`"),
                        Comment(rawValue: "\(language)/Help.md does not mention "
                            + "\(chord) (\(action.rawValue))"))
            }
        }
    }
}
