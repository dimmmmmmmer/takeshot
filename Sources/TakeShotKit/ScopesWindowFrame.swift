import AppKit
import SwiftUI

/// Adopts and then keeps the scopes window's frame (see
/// `CaptureController.keepScopesWindowFrame` for the persistence itself).
///
/// A backing view is the only way a SwiftUI `Window` scene hands out its
/// `NSWindow`: the scene has no API for the placement, and an operator who
/// dragged the scopes onto the second monitor expects to find them there the
/// next time the app opens. The view itself is `WindowReporter` in
/// `WindowChrome.swift` — the VANC title and the focus release need the same
/// hand-off.
struct ScopesWindowFrameKeeper: View {
    let controller: CaptureController

    var body: some View {
        WindowReporter { [controller] window in
            controller.keepScopesWindowFrame(window)
        }
    }
}
