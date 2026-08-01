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

    /// Calls back once per window it lands in. Not once ever: SwiftUI may hand
    /// a kept-alive view tree a NEW window when a scene reopens, and a report
    /// that never repeats leaves that window without whatever the callback was
    /// supposed to do to it (its chrome, its focus keeper).
    final class ReporterView: NSView {
        private let report: (NSWindow) -> Void
        private weak var reportedWindow: NSWindow?

        init(report: @escaping (NSWindow) -> Void) {
            self.report = report
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not created from a nib") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, window !== reportedWindow else { return }
            reportedWindow = window
            report(window)
        }
    }
}

/// Window-level chrome the SwiftUI scene modifiers cannot express.
enum WindowChrome {
    /// The app's window chrome: buttons over the content, no title strip, and
    /// the title STRING kept.
    ///
    /// Title text and title string are separate on purpose: the string is what
    /// the Window menu and the Mission Control label read, and an auxiliary
    /// window with an empty title is unfindable there. What the operator must
    /// not see is the title STRIP over the content — the app draws its own
    /// chrome and a system title row on one window out of five reads as a bug.
    ///
    /// One implementation, applied three ways: `AppDelegate` runs it over every
    /// window at launch and again as each one becomes key, and the two windows
    /// that must not wait for a key event — the VANC monitor and the scopes —
    /// ask for it from their own view tree through `monolithicWindowChrome()`.
    /// It used to exist twice, here and on the delegate, and the copies had
    /// drifted: only the delegate's cleared the toolbar, which is why the
    /// scopes window kept a system title bar the rest of the app does not have.
    static func makeMonolithic(_ window: NSWindow) {
        guard window.styleMask.contains(.titled) else { return }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.styleMask.insert(.fullSizeContentView)
        window.toolbar = nil
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

/// Keeps `releaseInitialFocus` in force for a window's whole LIFETIME.
///
/// The one-shot release at mount time is not enough, and that is exactly how
/// the Settings focus steal came back (owner item 23 after item 28): clearing
/// `initialFirstResponder` does not stick, because the hosting view
/// recalculates the key-view loop on layout and AppKit re-aims the keyboard at
/// the first text field EVERY time the window is made key with nothing
/// focused — so the project name was selected again on every reopen.
///
/// So the release is re-run at the moment that matters: each time the window
/// becomes key after having been closed (and once on its first key). Between
/// close and reopen is the ONLY window of time it fires in — a window that
/// merely lost key to the main window and got it back keeps whatever field the
/// operator had focused, because re-arming happens on `willClose` alone.
@MainActor
final class InitialFocusKeeper {
    /// One keeper per window, alive exactly as long as its window: the table
    /// holds the keeper strongly and the window weakly, so a second install on
    /// the same window (a remounted view tree) is a no-op instead of a second
    /// set of observers.
    private static let keepers =
        NSMapTable<NSWindow, InitialFocusKeeper>.weakToStrongObjects()

    static func install(on window: NSWindow) {
        guard keepers.object(forKey: window) == nil else { return }
        keepers.setObject(InitialFocusKeeper(window: window), forKey: window)
    }

    /// The next becoming-key is an OPEN, so the release must run. Armed at
    /// birth (the first key event is the first open) and re-armed by every
    /// close; disarmed by firing.
    private var pendingRelease = true
    private var observers: [NSObjectProtocol] = []

    private init(window: NSWindow) {
        // queue nil — the blocks run synchronously on the posting thread, and
        // AppKit posts both of these from the main thread: the release happens
        // BEFORE the key event that triggered it is followed by anything else
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window, queue: nil) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, self.pendingRelease,
                      let window = note.object as? NSWindow else { return }
                self.pendingRelease = false
                WindowChrome.releaseInitialFocus(of: window)
                // …and again on the next turn: SwiftUI installs the field's
                // focus after the window is already key
                DispatchQueue.main.async {
                    WindowChrome.releaseInitialFocus(of: window)
                }
            }
        })
        observers.append(center.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.pendingRelease = true }
        })
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

extension View {
    /// Give this scene's window the app's own chrome, without waiting for it to
    /// become key (see `WindowChrome.makeMonolithic`).
    func monolithicWindowChrome() -> some View {
        background(WindowReporter { window in
            WindowChrome.makeMonolithic(window)
        })
    }

    /// Open with nothing focused, so a stray keystroke cannot land in a text
    /// field the operator never clicked (see `WindowChrome.releaseInitialFocus`).
    ///
    /// Released on the next runloop turn as well as on mount: SwiftUI installs
    /// the window's first responder after the backing view lands, so clearing it
    /// only once, at mount time, clears nothing. And kept released across
    /// reopens by `InitialFocusKeeper` — the mount-time pass alone is the fix
    /// that regressed (see the keeper for why).
    func releasesInitialFocus() -> some View {
        background(WindowReporter { window in
            WindowChrome.releaseInitialFocus(of: window)
            DispatchQueue.main.async {
                WindowChrome.releaseInitialFocus(of: window)
            }
            InitialFocusKeeper.install(on: window)
        })
    }
}
