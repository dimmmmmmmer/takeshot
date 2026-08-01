import AppKit
import SwiftUI
import Testing

@testable import TakeShotKit

/// The two window behaviours no SwiftUI scene modifier expresses, both of them
/// things an operator notices before anything else: an auxiliary window that
/// keeps its NAME but not its title strip (owner item 26 — the VANC monitor was
/// the one window still drawing one), and a window that opens with nothing
/// focused (item 28 — Settings opened on the project name, the main window on
/// Cam, and a bumped key typed into a filename).
///
/// Asserted against a real `NSWindow` rather than a screenshot: both are
/// AppKit state, and both regress silently.
@MainActor
struct ViewWindowChromeTests {
    /// A titled window with two fields chained the way AppKit chains them —
    /// enough to tell "focus released" from "key-view loop destroyed".
    private struct Fixture {
        let window: NSWindow
        let first: NSTextField
        let second: NSTextField
    }

    private func windowWithFields() -> Fixture {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        let first = NSTextField(string: "project")
        first.frame = NSRect(x: 10, y: 70, width: 200, height: 22)
        let second = NSTextField(string: "A")
        second.frame = NSRect(x: 10, y: 30, width: 200, height: 22)
        content.addSubview(first)
        content.addSubview(second)
        window.contentView = content
        first.nextKeyView = second
        second.nextKeyView = first
        return Fixture(window: window, first: first, second: second)
    }

    // MARK: - item 26: the title strip

    /// The title STRING is what the Window menu lists, so it survives; the title
    /// TEXT over the content is what has to go.
    @Test func anAuxiliaryWindowKeepsItsNameAndLosesItsTitleText() {
        let window = windowWithFields().window
        window.title = L("vanc_monitor_title")
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false

        WindowChrome.makeMonolithic(window)

        #expect(window.titleVisibility == .hidden)
        #expect(window.titlebarAppearsTransparent)
        #expect(window.titlebarSeparatorStyle == .none)
        #expect(window.styleMask.contains(.fullSizeContentView))
        #expect(window.title == L("vanc_monitor_title"),
                "the window lost the name the Window menu lists it under")
    }

    /// Item 14: every auxiliary window gets the SAME chrome, from one
    /// implementation.
    ///
    /// The delegate and `WindowChrome` used to carry a copy each and the copies
    /// had drifted — only the delegate's cleared the toolbar — which is how the
    /// scopes window ended up wearing a system title bar the rest of the app
    /// does not have. Asserted against a window that has a toolbar, because
    /// that is the field the two disagreed on.
    @Test func theDelegateAndTheChromeAgreeOnWhatMonolithicMeans() {
        func styled(_ apply: (NSWindow) -> Void) -> NSWindow {
            let window = windowWithFields().window
            window.toolbar = NSToolbar(identifier: "test")
            window.titleVisibility = .visible
            window.titlebarAppearsTransparent = false
            apply(window)
            return window
        }
        let viaChrome = styled { WindowChrome.makeMonolithic($0) }
        let viaDelegate = styled { AppDelegate.makeMonolithic($0) }
        for window in [viaChrome, viaDelegate] {
            #expect(window.titleVisibility == .hidden)
            #expect(window.titlebarAppearsTransparent)
            #expect(window.titlebarSeparatorStyle == .none)
            #expect(window.styleMask.contains(.fullSizeContentView))
            #expect(window.toolbar == nil,
                    "a toolbar strip is exactly the row this removes")
        }
    }

    /// The borderless full-screen mirrors have no title bar to hide; forcing a
    /// style mask onto one is how a borderless window grows chrome.
    @Test func aBorderlessWindowIsLeftAlone() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.borderless], backing: .buffered, defer: false)

        WindowChrome.makeMonolithic(window)

        #expect(!window.styleMask.contains(.fullSizeContentView))
        #expect(!window.styleMask.contains(.titled))
    }

    // MARK: - item 28: the stolen keyboard

    @Test func aWindowOpensWithNoFieldHoldingTheKeyboard() throws {
        let fixture = windowWithFields()
        let (window, first, second) = (fixture.window, fixture.first, fixture.second)
        window.initialFirstResponder = first
        try #require(window.makeFirstResponder(first),
                     "the fixture could not focus a field to begin with")
        try #require(window.firstResponder !== window)

        let released = WindowChrome.releaseInitialFocus(of: window)

        #expect(released)
        #expect(window.firstResponder === window,
                "a text field still holds the keyboard")
        #expect(window.initialFirstResponder == nil,
                "re-showing the window would re-select the field")
        // the LOOP is untouched — tab still walks the same fields in order
        #expect(first.nextKeyView === second)
        #expect(second.nextKeyView === first)
    }

    /// "No field until the operator picks one" — not "no focus ever". Clicking
    /// into a field after the release has to work exactly as before.
    @Test func theOperatorCanStillFocusAFieldAfterTheRelease() throws {
        let fixture = windowWithFields()
        let (window, first) = (fixture.window, fixture.first)
        try #require(window.makeFirstResponder(first))
        WindowChrome.releaseInitialFocus(of: window)

        #expect(window.makeFirstResponder(first))
        #expect(window.firstResponder !== window)
    }

    /// Nothing focused already: no work done, and no claim that there was — the
    /// modifier releases twice (mount, then the next runloop turn) and the second
    /// pass must be a no-op rather than a second grab at the responder.
    @Test func releasingAnAlreadyUnfocusedWindowDoesNothing() {
        let window = windowWithFields().window
        window.makeFirstResponder(nil)

        #expect(!WindowChrome.releaseInitialFocus(of: window))
        #expect(window.firstResponder === window)
    }
}
