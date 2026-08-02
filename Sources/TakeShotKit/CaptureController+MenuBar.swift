import AppKit
import CaptureCore
import Foundation

/// The menu-bar (status item) presence: whether TakeShot keeps a handle in the
/// system menu bar, and putting it there or taking it away.
///
/// Off by default, and for exactly the reason the web remote is off by default:
/// a capture tool does not take a slot in the operator's menu bar until it is
/// asked to. What turning it on buys is a rolling take that stays visible — and
/// stoppable — with the main window closed or behind three other apps.
///
/// The activation policy is untouched (`.regular`). TakeShot is a full app with
/// a dock icon; the status item is an addition, never a replacement.
extension CaptureController {
    /// "Keep TakeShot in the menu bar" — nil/false is off.
    var keepInMenuBar: Bool { settings.keepInMenuBar ?? false }

    func applyMenuBarChange(from oldValue: CaptureSettings) {
        guard (oldValue.keepInMenuBar ?? false) != keepInMenuBar else { return }
        updateMenuBarPresence()
    }

    /// Install or remove the status item to match the setting. Idempotent —
    /// called from startup and from every settings write that changes it.
    func updateMenuBarPresence() {
        guard keepInMenuBar else {
            menuBar?.remove()
            menuBar = nil
            return
        }
        guard menuBar == nil else { return }
        menuBar = MenuBarPresence(model: MenuBarModel(controller: self))
    }
}
