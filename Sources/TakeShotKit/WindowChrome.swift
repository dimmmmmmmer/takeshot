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
    /// Main-actor by declaration, because that is where it is called from and
    /// what it is for: every reporter hands the window to something that goes
    /// on to touch AppKit state (chrome, first responder, frame).
    let report: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        ReporterView(report: report)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    /// Calls back once per window it lands in. Not once ever: SwiftUI may hand
    /// a kept-alive view tree a NEW window when a scene reopens, and a report
    /// that never repeats leaves that window without whatever the callback was
    /// supposed to do to it (its chrome, its focus keeper).
    final class ReporterView: NSView {
        private let report: @MainActor (NSWindow) -> Void
        private weak var reportedWindow: NSWindow?

        init(report: @escaping @MainActor (NSWindow) -> Void) {
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
///
/// Main-actor throughout: every member here reads or writes `NSWindow` state,
/// which AppKit owns on the main thread and the SDK now says so.
@MainActor
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

    /// Actual height of the window-button area: window height minus
    /// `contentLayoutRect`. Measured rather than a constant, because the strip
    /// is not one — it differs between a standard title bar and a hidden one,
    /// and Apple has changed it between releases.
    ///
    /// Floored at 20 so that a window which cannot answer yet (the two heights
    /// are equal before the style mask is settled, and for a borderless window
    /// they always are) still reserves room for the buttons instead of putting
    /// the content under them.
    static func titlebarInset(of window: NSWindow) -> CGFloat {
        max(20, window.frame.height - window.contentLayoutRect.height + 2)
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
    /// The window this keeper was installed on. Weak, and read back on the main
    /// actor rather than taken out of the notification: both observers below are
    /// registered for THIS window and no other, so the notification carries no
    /// information beyond the fact that it fired — and the window itself is
    /// AppKit state that belongs on the main actor, not in a `@Sendable` block.
    private weak var window: NSWindow?
    /// See `NotificationTokens`: the keeper is main-actor isolated, so it hands
    /// the observers to something whose `deinit` can give them back.
    private let observers = NotificationTokens()

    private init(window: NSWindow) {
        self.window = window
        // queue nil — the blocks run synchronously on the posting thread, and
        // AppKit posts both of these from the main thread: the release happens
        // BEFORE the key event that triggered it is followed by anything else
        let center = NotificationCenter.default
        observers.add(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.pendingRelease,
                      let window = self.window else { return }
                self.pendingRelease = false
                WindowChrome.releaseInitialFocus(of: window)
                // …and again on the next turn: SwiftUI installs the field's
                // focus after the window is already key
                // `@MainActor in` rather than a bare block: the queue is the
                // main one by name, and saying so is what lets the hop carry
                // the window — which is AppKit state, not a value.
                DispatchQueue.main.async { @MainActor in
                    WindowChrome.releaseInitialFocus(of: window)
                }
            }
        })
        observers.add(center.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.pendingRelease = true }
        })
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

    /// Keep `report` supplied with the height this window's title-bar buttons
    /// occupy, so the content can inset itself under them
    /// (see `WindowChrome.titlebarInset`).
    ///
    /// Measured from the window this view is IN. That replaced a 0.2 s
    /// `asyncAfter` that then took
    /// `NSApp.windows.first(where: { $0.styleMask.contains(.titled) })`, and
    /// both halves were wrong. The delay was a guess at when a window would
    /// exist at all: long enough to show the content at the default inset first
    /// on a quick launch, and no guarantee whatever on a slow one. The search
    /// then took the FIRST titled window in AppKit's list, which is the help or
    /// scopes window whenever one of those is already open — so the main window
    /// could inset its content by a different window's title bar. The reporter
    /// hands over the right window the moment there is one, so neither the wait
    /// nor the search is needed.
    ///
    /// Measured again on the next runloop turn, for the same reason
    /// `releasesInitialFocus` acts twice: SwiftUI is still applying the scene's
    /// `.hiddenTitleBar` when the backing view lands, and a window whose style
    /// mask has not settled reports the two heights as equal — the floor, not
    /// the real strip. This is a second measurement of the same window rather
    /// than a longer guess at when to take the first.
    func measuresTitlebarInset(
        _ report: @escaping @MainActor (CGFloat) -> Void) -> some View {
        background(WindowReporter { window in
            report(WindowChrome.titlebarInset(of: window))
            DispatchQueue.main.async { @MainActor in
                report(WindowChrome.titlebarInset(of: window))
            }
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
            DispatchQueue.main.async { @MainActor in
                WindowChrome.releaseInitialFocus(of: window)
            }
            InitialFocusKeeper.install(on: window)
        })
    }
}
