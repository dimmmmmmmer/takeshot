import AppKit
import CaptureCore
import SwiftUI

// The AppKit half of the punch-in zoom: the pinch and scroll input SwiftUI
// cannot express, and the grab-hand cursor.
//
// Split out of `AssistZoom.swift`, which holds the SwiftUI modifier and the
// drag gesture. This half is an NSView with a local event monitor and a
// tracking area, and its reasons for existing are all AppKit ones.

/// The AppKit half: pinch, scroll and the cursor. Internal rather than private
/// so the modifier in `AssistZoom.swift` can put it behind the player.
struct PunchEventSurface: NSViewRepresentable {
    let controller: CaptureController

    func makeNSView(context: Context) -> PunchEventView {
        let view = PunchEventView()
        PunchEventView.mountCount += 1
        connect(view)
        return view
    }

    func updateNSView(_ nsView: PunchEventView, context: Context) {
        connect(nsView)
    }

    static func dismantleNSView(_ nsView: PunchEventView, coordinator: ()) {
        nsView.stopMonitoring()
    }

    /// Closures rather than values: they are read at event time, so a pinch
    /// keeps working off the live magnification without this view having to
    /// re-render (and re-render the player under it) per event.
    private func connect(_ view: PunchEventView) {
        view.isPunchedIn = { [weak controller] in
            controller?.isPunchedIn ?? false
        }
        view.onMagnify = { [weak controller] factor, anchor, viewport in
            controller?.magnifyPunchIn(by: factor, at: anchor,
                                       viewport: viewport)
        }
        view.onScroll = { [weak controller] delta, viewport in
            controller?.panPunchIn(by: delta, viewport: viewport)
        }
    }
}

/// Trackpad and wheel input SwiftUI cannot express, plus the grab-hand cursor.
///
/// Events arrive through a local NSEvent monitor instead of by hit testing. A
/// hosted NSView that CLAIMS a point takes it away from whatever SwiftUI draws
/// on top of it — AppKit hands the event to the subview without asking SwiftUI
/// who is in front — and over the player that is the transport bar, the badges
/// and the wipe handle. `hitTest` returns nil for that reason, and the monitor
/// decides on the pointer being inside these bounds instead.
///
/// Inertia comes for free: when the fingers lift, AppKit keeps sending
/// scrollWheel events with a momentum phase, and they are handled like any
/// other — no physics of our own.
@MainActor
final class PunchEventView: NSView {
    /// How many have been mounted, ever. The zoom input has to reach the
    /// fullscreen players and not just the windowed one (item 19), and a mount
    /// count is what makes that observable from a headless render — the same
    /// trick `MetalPreviewLayer.presentCount` exists for.
    static fileprivate(set) var mountCount = 0

    var isPunchedIn: () -> Bool = { false }
    /// (relative factor, anchor in these bounds, bounds size) — the anchor is
    /// where the pointer is, and it is what the zoom stays centered on.
    var onMagnify: ((Double, CGPoint, CGSize) -> Void)?
    var onScroll: ((CGSize, CGSize) -> Void)?

    /// Flipped so `convert` answers in the y-down space every consumer of the
    /// anchor speaks (`ViewAssist.ImagePlacement.rect`, SwiftUI). Nothing else
    /// cares: this view draws nothing and declines every hit test.
    override var isFlipped: Bool { true }

    private var monitor: Any?
    /// The cursor half's own state (`AssistZoomCursor`) — module-internal
    /// rather than private for that reason, and touched nowhere else.
    var trackingArea: NSTrackingArea?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopMonitoring()
        } else {
            startMonitoring()
        }
    }

    private func startMonitoring() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.scrollWheel, .magnify]) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit {
        // deinit is nonisolated; the monitor is a plain object either way
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    /// nil consumes the event, the event itself passes it on.
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window, !bounds.isEmpty else {
            return event
        }
        let pointer = convert(event.locationInWindow, from: nil)
        guard bounds.contains(pointer) else { return event }
        switch event.type {
        case .magnify:
            // a pinch reports a RELATIVE delta per event; it always zooms —
            // the gesture means nothing else over a picture
            onMagnify?(1 + Double(event.magnification), pointer, bounds.size)
            return nil
        case .scrollWheel:
            // ⌘-scroll zooms (the macOS idiom): plain scroll cannot, because
            // it is already the pan while punched in, and a wheel that zooms
            // until 1.1x and pans after would change meaning mid-roll
            if event.modifierFlags.contains(.command) {
                onMagnify?(Self.wheelZoomFactor(
                    deltaY: event.scrollingDeltaY,
                    precise: event.hasPreciseScrollingDeltas),
                    pointer, bounds.size)
                return nil
            }
            guard isPunchedIn() else { return event } // nothing to pan
            onScroll?(scrollDelta(of: event), bounds.size)
            return nil
        default:
            return event
        }
    }

    /// A wheel notch is worth this many points of precise scroll — shared by
    /// the pan and the zoom so a notch feels the same in both.
    private static let pointsPerLine: CGFloat = 16

    /// Scroll distance in points, in the same sense as a drag of the picture.
    private func scrollDelta(of event: NSEvent) -> CGSize {
        // a trackpad reports points; a wheel notch reports lines
        let factor: CGFloat = event.hasPreciseScrollingDeltas
            ? 1 : Self.pointsPerLine
        return CGSize(width: event.scrollingDeltaX * factor,
                      height: event.scrollingDeltaY * factor)
    }

    /// A ⌘-scroll step as a relative magnification factor. Scrolling up zooms
    /// in. `exp` keeps the steps symmetric — +N points exactly undoes −N — and
    /// the clamp caps what a fast-rolled, OS-accelerated notch can jump in one
    /// event. Internal and NSEvent-free so the math itself is testable.
    static func wheelZoomFactor(deltaY: CGFloat, precise: Bool) -> Double {
        let points = Double(deltaY * (precise ? 1 : pointsPerLine))
        // 0.006/point ≈ 1.1x per wheel notch, ~2x per 8 cm trackpad swipe
        return min(2, max(0.5, exp(points * 0.006)))
    }

    /// Never in the hit-test chain — see the type comment.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
