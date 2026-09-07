import Foundation
import Testing

@testable import TakeShotKit

/// **A control that shows only a shape has to say its name out loud.**
///
/// The app's controls are icons, and each carries a `.help` — a tooltip, seen
/// by hovering, with a mouse, while looking at the screen. VoiceOver reads a
/// button's LABEL, and the label of a button whose content is a `Circle` and a
/// `RoundedRectangle` is nothing at all: the REC button, the one control an
/// operator reaches for without looking, announced itself as "button".
///
/// Four `accessibilityLabel`s existed across roughly fifty icon-only controls
/// and the REC button was not one of them. `View.controlHelp` sets both from
/// one string; this is what keeps the controls that matter on set from
/// drifting back to a bare tooltip.
struct ViewControlLabelRuleTests {
    /// The controls an operator uses without looking at them.
    private static let onSet = ["FooterBar", "MarkerControls",
                                "CompareControls", "ScopesPanelChrome",
                                "ChromaKeyControls", "TakeRowControls"]

    private static func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TakeShotKit")
        return try String(
            contentsOf: root.appendingPathComponent("\(name).swift"),
            encoding: .utf8)
    }

    /// Every icon-only button in these files names itself.
    ///
    /// Detected as a `.help(` whose button label is an `Image` and no `Text`:
    /// a control with words in it already says them, and `.help` there is the
    /// EXTRA sentence a tooltip is for rather than the only one there is.
    @Test func everyIconOnlyControlOnSetNamesItself() throws {
        var bare: [String] = []
        for name in Self.onSet {
            let lines = try Self.source(name).components(separatedBy: "\n")
            for (index, line) in lines.enumerated()
            where line.contains(".help(") && !line.contains(".controlHelp(") {
                let window = lines[max(0, index - 14)..<index].joined(separator: "\n")
                guard window.contains("Image(systemName:"),
                      window.contains("label:"),
                      let afterLabel = window.components(separatedBy: "label:").last,
                      !afterLabel.contains("Text(")
                else { continue }
                bare.append("\(name):\(index + 1) "
                    + line.trimmingCharacters(in: .whitespaces))
            }
        }
        #expect(bare.isEmpty, """
            these icon-only controls carry a tooltip and no name, so a screen \
            reader announces them as "button" — use controlHelp:
            \(bare.joined(separator: "\n"))
            """)
    }

    /// The REC button by name, because it is the one that matters most and a
    /// walk that stopped recognising the shape would pass in silence.
    @Test func theRecordButtonNamesItself() throws {
        let source = try Self.source("FooterBar")
        #expect(source.contains(".controlHelp("),
                "the REC button is back to a tooltip nobody can hear")
    }

    /// …and the modifier still does both halves. A `controlHelp` that had
    /// quietly become an alias for `help` would satisfy every line above.
    @Test func theModifierSetsBothTheTooltipAndTheName() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TakeShotKit")
        let source = try String(
            contentsOf: root.appendingPathComponent("ControlLabel.swift"),
            encoding: .utf8)
        #expect(source.contains("accessibilityLabel"))
        #expect(source.contains("help(text)"))
    }
}
