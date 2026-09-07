import Foundation
import Testing

@testable import TakeShotKit

/// **Nothing focusable may sit over the panel's scroll views.**
///
/// A scroll wheel is an AppKit responder-chain event: it goes to whatever is
/// under the pointer. `.focusable()` applied to a container puts a full-size
/// focus view OVER its content, so the takes list and the Other-content list
/// would not scroll — while CLICKS still worked, because SwiftUI routes those
/// through its own gesture system. The panel therefore looked entirely normal
/// and simply refused the wheel (owner: "скролл колесом мышки почему то не
/// работает ни на тейках ни на другом контенте… в настройках общих работало").
///
/// The panel still needs focus — Delete has to reach it — so the target moved
/// BEHIND the content, where it takes the same key command and intercepts
/// nothing.
///
/// Asserted on the source. The defect is invisible to a headless render: an
/// `NSHostingView` with no window hit-tests to itself either way, which is
/// what made this cost an afternoon to find rather than a minute.
struct ViewPanelScrollRuleTests {
    private static func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TakeShotKit")
        return try String(
            contentsOf: root.appendingPathComponent("\(name).swift"),
            encoding: .utf8)
    }

    /// The focus target is inside a `.background`, which is under the content.
    @Test func thePanelsFocusTargetIsBehindItsContent() throws {
        let code = try Self.source("TakeListView")
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        let focusable = try #require(
            code.range(of: ".focusable()"),
            Comment(rawValue: "the panel can no longer take focus, so Delete "
                + "cannot reach it"))
        let background = try #require(
            code.range(of: ".background {"),
            Comment(rawValue: "the focus target is not in a background"))
        #expect(background.lowerBound < focusable.lowerBound, """
            `.focusable()` is applied outside the background again, which puts \
            a full-size focus view over the list and the wheel stops working
            """)
        // …and it is applied to a clear colour rather than to the sections,
        // which is the whole distinction.
        #expect(code.contains("Color.clear\n                    .focusable()"),
                "the focus target is not the clear background")
    }

    /// The panel still owns the Delete command — moving the target must not
    /// have taken the key with it.
    @Test func thePanelStillTakesTheDeleteCommand() throws {
        let code = try Self.source("TakeListView")
        #expect(code.contains(".onDeleteCommand"),
                "Delete no longer reaches the panel at all")
        #expect(code.contains("trashPromptOpen = true"),
                "Delete no longer opens the confirmation")
    }
}
