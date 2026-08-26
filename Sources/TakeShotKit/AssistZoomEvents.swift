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

/// What an event carries that the rule needs, as a value.
///
/// A struct rather than eight parameters, because that is what these are: one
/// reading off one `NSEvent`. It also lets a test state only the facts a case
/// is about.
struct PunchEvent {
    var type: NSEvent.EventType
    var magnification: CGFloat = 0
    var modifiers: NSEvent.ModifierFlags = []
    var scrollingDelta: CGSize = .zero
    /// A trackpad reports points; a wheel notch reports lines.
    var precise: Bool = true
}

/// What one pinch or scroll over the picture amounts to.
enum PunchInput: Equatable {
    /// Not ours: hand the event on untouched.
    case ignore
    /// Zoom by a relative factor, anchored where the pointer is.
    case magnify(Double)
    /// Move the picture by this many points.
    case pan(CGSize)
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

    /// Held by an object of its own so the monitor is given back when the view
    /// is released, without the view's nonisolated `deinit` having to reach
    /// main-actor state to do it — see `EventMonitorToken`.
    private let monitor = EventMonitorToken()
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
        guard !monitor.isActive else { return }
        monitor.set(NSEvent.addLocalMonitorForEvents(
            matching: [.scrollWheel, .magnify]) { [weak self] event in
            self?.handle(event) ?? event
        })
    }

    func stopMonitoring() {
        monitor.remove()
    }

    /// nil consumes the event, the event itself passes it on.
    ///
    /// Reads the facts off the event and applies the outcome; the RULE is
    /// `decide`, which is a function of those facts alone.
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window else { return event }
        let pointer = convert(event.locationInWindow, from: nil)
        let facts = PunchEvent(
            type: event.type, magnification: event.magnification,
            modifiers: event.modifierFlags,
            scrollingDelta: CGSize(width: event.scrollingDeltaX,
                                   height: event.scrollingDeltaY),
            precise: event.hasPreciseScrollingDeltas)
        switch Self.decide(facts, pointer: pointer, bounds: bounds,
                           isPunchedIn: isPunchedIn()) {
        case .ignore:
            return event
        case .magnify(let factor):
            onMagnify?(factor, pointer, bounds.size)
            return nil
        case .pan(let delta):
            onScroll?(delta, bounds.size)
            return nil
        }
    }

    /// What a pinch or a scroll over the picture MEANS.
    ///
    /// A value rather than three calls inside the monitor, because the monitor
    /// itself cannot be driven from a test: a local `NSEvent` monitor wants a
    /// real application event queue, and a synthesized event cannot carry the
    /// window number that would make it match. Stated over the facts an event
    /// carries, the rule is ordinary code — and it is a rule worth pinning,
    /// since it decides whether a wheel zooms or pans, which is the difference
    /// between framing a shot and losing it mid-roll.
    static func decide(_ event: PunchEvent, pointer: CGPoint, bounds: CGRect,
                       isPunchedIn: Bool) -> PunchInput {
        guard !bounds.isEmpty, bounds.contains(pointer) else { return .ignore }
        switch event.type {
        case .magnify:
            // a pinch reports a RELATIVE delta per event; it always zooms —
            // the gesture means nothing else over a picture
            return .magnify(1 + Double(event.magnification))
        case .scrollWheel:
            // ⌘-scroll zooms (the macOS idiom): plain scroll cannot, because
            // it is already the pan while punched in, and a wheel that zoomed
            // until 1.1x and panned after would change meaning mid-roll
            if event.modifiers.contains(.command) {
                return .magnify(
                    wheelZoomFactor(deltaY: event.scrollingDelta.height,
                                    precise: event.precise))
            }
            guard isPunchedIn else { return .ignore } // nothing to pan
            // a trackpad reports points; a wheel notch reports lines
            let factor: CGFloat = event.precise ? 1 : pointsPerLine
            return .pan(CGSize(width: event.scrollingDelta.width * factor,
                               height: event.scrollingDelta.height * factor))
        default:
            return .ignore
        }
    }

    /// A wheel notch is worth this many points of precise scroll — shared by
    /// the pan and the zoom so a notch feels the same in both.
    private static let pointsPerLine: CGFloat = 16

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
