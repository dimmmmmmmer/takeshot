import AppKit
import SwiftUI

/// **The takes panel scrolls its own wheel.**
///
/// This is a workaround, and it says so. What it works around was measured in
/// the running application rather than guessed at, and every other explanation
/// was ruled out the same way:
///
///   * 886 real wheel events reach the app over the panel, carrying precise
///     deltas quantised in ~103pt steps — a mouse driver turning notches into
///     continuous scrolls;
///   * they are attributed to the main window and hit-test into the panel's
///     own scroll view, which has hundreds of points of document to spare;
///   * they survive every local monitor (a second monitor installed LAST in
///     line saw 81 of the 84 the first one did — the three it missed are the
///     ones before it was armed);
///   * the responder chain from the hit view reaches the scroll view;
///   * handing that SAME view the SAME kind of event by hand scrolls it, 120
///     points, line deltas and precise deltas alike;
///   * three programmatic scrolls to 60, 200 and 340 all hold;
///   * and after AppKit's own dispatch the offset is unchanged. 886 times.
///
/// Ruled out by removing them and measuring again: the split views, the
/// panel's focusable background, the root tap gesture, the predominant-axis
/// lock, a continuously rebuilding panel, a pinned scroll offset, the mouse
/// itself (the Settings window scrolls with it), and a starved main thread
/// (8 late run-loop turns in 600, worst 25ms).
///
/// So the event arrives, the machinery works when driven, and AppKit's
/// delivery does nothing. Until that last step is understood, the panel
/// delivers the event itself.
///
/// **It claims as little as it can.** Only CONTINUOUS events — the shape that
/// is measurably lost; a legacy notch is handed straight back, because those
/// were measured working. Only over the panel's own rectangle. And only when
/// the scroll would actually move something: at either end of the document the
/// event is passed on rather than silently eaten, so nothing outside the panel
/// changes behaviour at all.
enum PanelWheelRelay {
    /// Where the panel is, in the window it is in. Written by `PanelWheelZone`
    /// as the panel lays out, read by the monitor on each event.
    @MainActor private static weak var zone: NSView?
    @MainActor private static var token: Any?

    @MainActor
    static func adopt(_ view: NSView?) {
        zone = view
    }

    /// Whether the panel has told the relay where it is. Mounting the panel
    /// must register a rectangle, or the relay is installed and inert — which
    /// looks exactly like the bug it exists for, and has no size to measure.
    @MainActor
    static var hasZone: Bool { zone != nil }

    /// Install the monitor. Idempotent, and safe to call before any window
    /// exists — it consults `zone`, which is nil until the panel mounts.
    @MainActor
    static func install() {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            // The DECISION crosses the isolation boundary, not the event:
            // `NSEvent` is not `Sendable`, and handing one back out of an
            // `assumeIsolated` is a compile error rather than a race.
            let consumed = MainActor.assumeIsolated { handle(event) }
            return consumed ? nil : event
        }
    }

    /// True consumes the event, false passes it on — the same contract
    /// `PunchEventView.handle` states, and for the same reason: a monitor that
    /// swallows what it does not act on is a bug that looks exactly like the
    /// one this file exists for.
    @MainActor
    private static func handle(_ event: NSEvent) -> Bool {
        guard let zone, let window = zone.window, event.window === window,
              let scroll = scroller(under: event, in: window),
              zone.frame(in: window).contains(event.locationInWindow)
        else { return false }

        let document = scroll.documentView?.frame.height ?? 0
        let clip = scroll.contentView.bounds.height
        let offset = scroll.contentView.bounds.origin.y
        guard claims(precise: event.hasPreciseScrollingDeltas,
                     delta: event.scrollingDeltaY, offset: offset,
                     document: document, clip: clip) else { return false }

        let moved = scrolled(offset: offset, by: event.scrollingDeltaY,
                             document: document, clip: clip)
        scroll.contentView.scroll(to: CGPoint(x: scroll.contentView.bounds.origin.x,
                                              y: moved))
        scroll.reflectScrolledClipView(scroll.contentView)
        return true
    }

    /// The scroll view under the pointer, if the pointer is over one.
    @MainActor
    private static func scroller(under event: NSEvent,
                                 in window: NSWindow) -> NSScrollView? {
        var view = window.contentView?.hitTest(event.locationInWindow)
        while let step = view {
            if let scroll = step as? NSScrollView { return scroll }
            view = step.superview
        }
        return nil
    }

    /// **Whether this event is the panel's to deliver.**
    ///
    /// Continuous only: a legacy notch reaches the scroll view perfectly well
    /// and is none of this file's business. Something to scroll only: a
    /// document no taller than its clip has nowhere to go. And it must
    /// actually MOVE — at the top of the list an upward scroll changes
    /// nothing, and consuming it would stop it reaching anything that could
    /// use it.
    static func claims(precise: Bool, delta: CGFloat, offset: CGFloat,
                       document: CGFloat, clip: CGFloat) -> Bool {
        guard precise, delta != 0, document > clip else { return false }
        return scrolled(offset: offset, by: delta,
                        document: document, clip: clip) != offset
    }

    /// Where a wheel event of `delta` puts a view sitting at `offset`.
    ///
    /// `scrollingDeltaY` is already in points for a continuous event and
    /// already carries the operator's natural-scrolling preference, so there is
    /// no direction to decide here and no line height to guess at — which is
    /// half the reason this only claims continuous events.
    static func scrolled(offset: CGFloat, by delta: CGFloat,
                         document: CGFloat, clip: CGFloat) -> CGFloat {
        let room = max(0, document - clip)
        return min(room, max(0, offset - delta))
    }
}

extension NSView {
    /// This view's frame in `window`'s coordinates.
    func frame(in window: NSWindow) -> CGRect {
        convert(bounds, to: window.contentView)
    }
}

/// Reports the takes panel's rectangle to `PanelWheelRelay`, and nothing else.
///
/// Mounted in the panel's `.background`, beside the focus target and for the
/// same reason: a view in FRONT of the content is that content unreachable
/// (`ViewPanelScrollRuleTests`). It draws nothing and declines every hit test,
/// so being in the background costs it nothing either.
struct PanelWheelZone: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = ZoneView()
        PanelWheelRelay.adopt(view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        PanelWheelRelay.adopt(nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        MainActor.assumeIsolated { PanelWheelRelay.adopt(nil) }
    }

    final class ZoneView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
