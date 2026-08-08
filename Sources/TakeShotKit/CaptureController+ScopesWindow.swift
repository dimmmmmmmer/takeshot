import AppKit
import Foundation

/// Where the operator left the scopes window.
///
/// Manual rather than `setFrameAutosaveName`: AppKit's autosave writes to
/// `UserDefaults.standard` under a name of its own, which a test may not touch
/// and the controller's injected suite cannot see. This way the frame travels
/// with the rest of the app's state.
///
/// Split out of `+Windows`, which builds the borderless fullscreen surfaces and
/// the hardware playout mirror.
extension CaptureController {

    /// Where the scopes window was last left, in the app's own defaults.
    ///
    /// Manual rather than `setFrameAutosaveName`: AppKit's autosave writes to
    /// `UserDefaults.standard` under a name of its own, which a test may not
    /// touch and the controller's injected suite cannot see. This way the frame
    /// travels with the rest of the app's state.
    static let scopesFrameKey = "scopesWindowFrame"

    /// Adopt the stored frame and keep it up to date as the operator moves or
    /// resizes the window.
    ///
    /// Order matters: the frame is READ before anything is observed. A SwiftUI
    /// `Window` scene has already placed the window by the time its content
    /// appears, so an observer installed first would immediately save that
    /// default placement over the operator's.
    func keepScopesWindowFrame(_ window: NSWindow) {
        if let frame = savedScopesWindowFrame() {
            window.setFrame(frame, display: false)
        }
        let moves = [NSWindow.didMoveNotification,
                     NSWindow.didEndLiveResizeNotification]
        scopesFrame.aim(at: window, observing: moves) { [weak self] in
            // AppKit posts these on the main thread; the hop is only for the
            // main-actor isolation the compiler cannot see through a
            // notification block. The frame is read on the far side of it,
            // where the window lives — a window is not a value and has no
            // business travelling out of a notification.
            Task { @MainActor in
                guard let self, let moved = self.scopesFrame.window else {
                    return
                }
                self.saveScopesWindowFrame(moved.frame)
            }
        }
    }

    func saveScopesWindowFrame(_ frame: NSRect) {
        defaults.set(NSStringFromRect(frame), forKey: Self.scopesFrameKey)
    }

    /// The stored frame, or nil when there is none, it is unusably small, or it
    /// lands on a display that is no longer attached.
    func savedScopesWindowFrame(
        screens: [NSRect]? = nil) -> NSRect? {
        guard let text = defaults.string(forKey: Self.scopesFrameKey) else {
            return nil
        }
        let visible = screens ?? NSScreen.screens.map(\.visibleFrame)
        return Self.usableScopesFrame(NSRectFromString(text), screens: visible)
    }

    /// A saved frame is only used when it is big enough to hold the panel's own
    /// minimum and still overlaps a screen the operator can reach. Coming back
    /// from a two-monitor cart to a laptop must not hide the window off-screen.
    static func usableScopesFrame(_ frame: NSRect,
                                  screens: [NSRect]) -> NSRect? {
        guard frame.width >= 420, frame.height >= 260 else { return nil }
        let visible = screens.contains {
            let overlap = $0.intersection(frame)
            return overlap.width >= 120 && overlap.height >= 80
        }
        return visible ? frame : nil
    }

}

/// The scopes window's frame watch: the move/resize observers and the window
/// they are on.
///
/// One object because they are one fact — a set of observers means nothing
/// without the window it watches, and re-aiming has to replace both. The window
/// is weak (SwiftUI owns it) and the observers are given back when this is
/// re-aimed or released (see `NotificationTokens`).
@MainActor
final class ScopesFrameWatch {
    /// Read back here on the main actor rather than taken out of the
    /// notification: the observers are registered for THIS window and no other,
    /// so what the notification carries is only that it moved.
    private(set) weak var window: NSWindow?
    private let observers = NotificationTokens()

    /// Watch `window` for `names`, dropping whatever was watched before.
    func aim(at window: NSWindow, observing names: [Notification.Name],
             onChange: @escaping @Sendable () -> Void) {
        observers.removeAll()
        self.window = window
        for name in names {
            observers.add(NotificationCenter.default.addObserver(
                forName: name, object: window, queue: .main) { _ in onChange() })
        }
    }
}
