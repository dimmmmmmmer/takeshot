import AppKit
import SwiftUI

/// **The empty strip along the top of the window behaves like a title bar.**
///
/// The window is `.hiddenTitleBar` with `fullSizeContentView`, so the app's own
/// content reaches the top edge and the strip the traffic lights sit in is
/// SwiftUI's, not AppKit's. A `Color.clear` filled it — and a clear colour IS
/// hit-tested — so every click there was swallowed: dragging the window by its
/// top edge worked only over the actual titlebar buttons, and a double-click
/// did nothing at all (owner: "клик сверху по пустым местам главного окна
/// двойной не расширяет его на весь дисплей").
///
/// Both behaviours are implemented rather than inherited, because there is no
/// titlebar view under the pointer to inherit them from:
///
/// - a drag calls `performDrag`, which is AppKit's own window drag including
///   the snap-to-edge and Spaces behaviour;
/// - a double-click performs **the action the user chose in System Settings**
///   (`AppleActionOnDoubleClick`), which is Zoom by default but is Minimize or
///   None for some people — a window that always zoomed would be overriding a
///   preference this strip is standing in for.
///
/// `mouseDownCanMoveWindow` stays FALSE on purpose: with it true AppKit takes
/// the drag and the view never sees `mouseDown`, so the double-click would be
/// unreachable. Doing both here is the only way to have both.
struct WindowDragZone: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragZoneView() }

    func updateNSView(_ view: NSView, context: Context) {}
}

private final class DragZoneView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return super.mouseDown(with: event) }
        guard event.clickCount < 2 else {
            Self.doubleClickAction().perform(on: window)
            return
        }
        window.performDrag(with: event)
    }

    /// What a double-click on a title bar does on THIS Mac.
    ///
    /// The key is unset until the user changes it, and unset means Zoom —
    /// which is what the owner is asking for and what the default reading has
    /// to be.
    static func doubleClickAction() -> TitleBarDoubleClick {
        TitleBarDoubleClick.reading(UserDefaults.standard
            .string(forKey: "AppleActionOnDoubleClick"))
    }
}

/// The three answers `AppleActionOnDoubleClick` can give. Its own type so the
/// mapping is testable without a window — the click itself is not reachable
/// from a headless run.
enum TitleBarDoubleClick: Equatable {
    case zoom
    case minimize
    case none

    @MainActor
    func perform(on window: NSWindow) {
        switch self {
        case .zoom: window.zoom(nil)
        case .minimize: window.miniaturize(nil)
        case .none: break
        }
    }

    /// The reading of the stored preference, as a pure function of the string.
    static func reading(_ stored: String?) -> TitleBarDoubleClick {
        switch stored {
        case "Minimize": return .minimize
        case "None": return .none
        default: return .zoom
        }
    }
}
