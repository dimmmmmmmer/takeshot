import AppKit
import SwiftUI

/// The app's windows, by the scene id SwiftUI knows each one under.
///
/// A named case rather than a string literal at every call site: a typo in
/// `openWindow(id:)` is completely silent — the call does nothing at all, and
/// the button that made it looks broken with no diagnostic anywhere. The raw
/// values are the scene ids in `TakeShotApp` and must not drift from them.
enum AppWindowID: String, CaseIterable {
    /// The one main window. A `Window` scene, not a `WindowGroup` — see
    /// `AppWindows` below for why that distinction is load-bearing.
    case main
    case help
    case scopes
    case slate
    case vancMonitor = "vanc-monitor"
    case settings
}

/// Where the app's windows are, and the one way to put one in front of the
/// operator.
///
/// The rule this exists to enforce: **TakeShot never opens a second copy of a
/// window it already has.** For the main window that is not cosmetic. Two
/// `ContentView`s mean two `ViewerSurface`s driven by one controller, and a
/// CALayer can be hosted by exactly ONE NSView (see the preview display rule in
/// CLAUDE.md) — the second mount takes the preview layer away from the first,
/// and on set that looks like the board has failed.
///
/// Every scene is single-instance by construction now (`Window`, not
/// `WindowGroup`), so `openWindow(id:)` is documented to bring an existing
/// window forward rather than make another. What it does NOT do is activate the
/// app or un-minimize the window, and from a menu-bar item, a second display or
/// a click on a background app both of those are the entire point of the click.
/// So the window is taken by the hand when there is one, and the scene is only
/// asked for a new one when there is not.
@MainActor
enum AppWindows {
    /// Scene id → the window SwiftUI built for it. The values are held WEAKLY:
    /// a window SwiftUI tears down on close must not be kept alive by this
    /// table, and a stale entry would be worse than no entry — `present` would
    /// order a dead window front and never ask the scene to reopen.
    private static let windows =
        NSMapTable<NSString, NSWindow>.strongToWeakObjects()

    /// The scene graph's own opener, captured from a live view tree.
    ///
    /// `OpenWindowAction` is the only way to reopen a `Window` scene that has
    /// been closed, and two callers have no SwiftUI environment to read it
    /// from: the app delegate's dock-reopen handler and the menu-bar item.
    /// The action is a value bound to the app's scene graph, not to the view it
    /// was read in, so it stays usable after that view is gone.
    private static var opener: OpenWindowAction?

    static func remember(_ action: OpenWindowAction) { opener = action }

    static func register(_ window: NSWindow, as id: AppWindowID) {
        windows.setObject(window, forKey: id.rawValue as NSString)
    }

    static func window(_ id: AppWindowID) -> NSWindow? {
        windows.object(forKey: id.rawValue as NSString)
    }

    /// Whether that window is on screen right now. A miniaturized window is
    /// NOT visible by this measure, which is the answer the callers want:
    /// clicking the dock icon with the window in the Dock has to restore it.
    static func isOpen(_ id: AppWindowID) -> Bool {
        window(id)?.isVisible ?? false
    }

    /// What `present` is about to do. Split out because it is the whole rule —
    /// ask the scene for a window ONLY when there is not one already — and it
    /// is the part worth asserting; `OpenWindowAction` cannot be constructed
    /// outside a scene graph, so the acting half cannot be.
    enum Route: Equatable {
        /// The window exists and is on screen: order it front.
        case focus
        /// It is in the Dock: it has to come out before it can take focus.
        case deminiaturize
        /// There is no window — ask the scene for one.
        case reopen
    }

    static func route(for id: AppWindowID) -> Route {
        guard let window = window(id) else { return .reopen }
        if window.isMiniaturized { return .deminiaturize }
        return window.isVisible ? .focus : .reopen
    }

    /// Bring `id` in front of the operator, reopening its scene only if the
    /// window is really gone.
    ///
    /// `opening` is the caller's own `@Environment(\.openWindow)` where there
    /// is one; the remembered action covers the callers that have no
    /// environment at all.
    static func present(_ id: AppWindowID, opening open: OpenWindowAction? = nil) {
        // Focus means focus: a window ordered front inside an app that is not
        // frontmost is still behind whatever the operator is looking at, and
        // `openWindow(id:)` does not activate the app on its own.
        NSApplication.shared.activate(ignoringOtherApps: true)
        switch route(for: id) {
        case .deminiaturize:
            window(id)?.deminiaturize(nil)
            window(id)?.makeKeyAndOrderFront(nil)
        case .focus:
            window(id)?.makeKeyAndOrderFront(nil)
        case .reopen:
            if let open {
                open(id: id.rawValue)
            } else if let opener {
                opener(id: id.rawValue)
            }
        }
    }
}

/// Records which `NSWindow` a scene landed in, and hands the scene graph's
/// opener to `AppWindows`.
///
/// A `ViewModifier` rather than a line in each scene's own view: the reporter
/// has to sit in the view tree (a SwiftUI scene hands out its window no other
/// way — see `WindowReporter`), and every scene needs exactly the same two
/// calls made with its own id.
private struct AppWindowRegistration: ViewModifier {
    let id: AppWindowID
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.background(WindowReporter { window in
            AppWindows.register(window, as: id)
            AppWindows.remember(openWindow)
        })
    }
}

extension View {
    /// Register this scene's window under `id`, so every opener in the app can
    /// focus it instead of asking for another one.
    func registersAppWindow(_ id: AppWindowID) -> some View {
        modifier(AppWindowRegistration(id: id))
    }
}
