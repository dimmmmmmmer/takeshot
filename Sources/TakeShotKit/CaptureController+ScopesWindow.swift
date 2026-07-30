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
        for token in scopesFrameObservers {
            NotificationCenter.default.removeObserver(token)
        }
        scopesFrameObservers = [NSWindow.didMoveNotification,
                                NSWindow.didEndLiveResizeNotification].map { name in
            NotificationCenter.default.addObserver(
                forName: name, object: window, queue: .main
            ) { [weak self] note in
                guard let moved = note.object as? NSWindow else { return }
                let frame = moved.frame
                // AppKit posts this on the main thread; the hop is only for the
                // main-actor isolation the compiler cannot see through a
                // notification block
                Task { @MainActor in self?.saveScopesWindowFrame(frame) }
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
