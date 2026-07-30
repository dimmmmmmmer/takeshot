import AppKit
import SwiftUI

/// Adopts and then keeps the scopes window's frame (see
/// `CaptureController.keepScopesWindowFrame` for the persistence itself).
///
/// A backing view is the only way a SwiftUI `Window` scene hands out its
/// `NSWindow`: the scene has no API for the placement, and an operator who
/// dragged the scopes onto the second monitor expects to find them there the
/// next time the app opens.
struct ScopesWindowFrameKeeper: NSViewRepresentable {
    let controller: CaptureController

    func makeNSView(context: Context) -> NSView {
        WindowReporter { [controller] window in
            controller.keepScopesWindowFrame(window)
        }
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    /// Calls back once, as soon as it has a window to report.
    final class WindowReporter: NSView {
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
