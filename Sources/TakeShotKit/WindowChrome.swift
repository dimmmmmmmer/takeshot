import AppKit
import SwiftUI

/// Reaches the `NSWindow` behind a SwiftUI scene and does something to it once.
///
/// A backing view is the only way a SwiftUI `Window` hands out its window: the
/// scene has no API for the title bar, the placement or the first responder, and
/// all three are things this app has to set itself. Shared by the scopes frame
/// keeper, the VANC title suppression and the focus release rather than
/// re-implemented three times.
struct WindowReporter: NSViewRepresentable {
    let report: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        ReporterView(report: report)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    /// Calls back once, as soon as it has a window to report.
    final class ReporterView: NSView {
        private let report: (NSWindow) -> Void
        private var reported = false

        init(report: @escaping (NSWindow) -> Void) {
            self.report = report
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not created from a nib") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard !reported, let window else { return }
            reported = true
            report(window)
        }
    }
}

/// Window-level chrome the SwiftUI scene modifiers cannot express.
enum WindowChrome {
    /// Hide a window's title text while KEEPING the title string.
    ///
    /// The two are separate on purpose: the string is what the Window menu and
    /// the Mission Control label read, and an auxiliary window with an empty
    /// title is unfindable there. What the operator must not see is the title
    /// STRIP over the content — the app draws its own chrome and a system title
    /// row on one window out of five reads as a bug.
    static func hideTitle(of window: NSWindow) {
        guard window.styleMask.contains(.titled) else { return }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.styleMask.insert(.fullSizeContentView)
    }

    /// Drop the focus AppKit handed the window when it opened.
    ///
    /// AppKit gives a freshly keyed window a first responder off its key-view
    /// loop, and SwiftUI puts a text field first in both windows that have one:
    /// Settings opened with the project name selected and the main window with
    /// Cam. On set that is a live keyboard pointed at a filename — a bumped key
    /// renames the project, and nobody is looking at the footer while they are
    /// watching the frame.
    ///
    /// Only the CURRENT responder is dropped. `initialFirstResponder` is cleared
    /// so re-showing the window cannot re-select the field, but the key-view LOOP
    /// itself is untouched: Tab still walks the same fields in the same order,
    /// and clicking into one still works.
    ///
    /// Returns whether a responder was actually released — the tests assert on
    /// that rather than on a screenshot.
    @discardableResult
    static func releaseInitialFocus(of window: NSWindow) -> Bool {
        window.initialFirstResponder = nil
        // the window itself as first responder IS "nothing focused"
        guard let responder = window.firstResponder, responder !== window else {
            return false
        }
        return window.makeFirstResponder(nil)
    }
}

extension View {
    /// Keep the window's title out of its title bar (see `WindowChrome.hideTitle`).
    func hidesWindowTitle() -> some View {
        background(WindowReporter { window in
            WindowChrome.hideTitle(of: window)
        })
    }

    /// Open with nothing focused, so a stray keystroke cannot land in a text
    /// field the operator never clicked (see `WindowChrome.releaseInitialFocus`).
    ///
    /// Released on the next runloop turn as well as on mount: SwiftUI installs
    /// the window's first responder after the backing view lands, so clearing it
    /// only once, at mount time, clears nothing.
    func releasesInitialFocus() -> some View {
        background(WindowReporter { window in
            WindowChrome.releaseInitialFocus(of: window)
            DispatchQueue.main.async {
                WindowChrome.releaseInitialFocus(of: window)
            }
        })
    }
}
