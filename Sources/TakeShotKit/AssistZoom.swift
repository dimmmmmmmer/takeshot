import AppKit
import CaptureCore
import SwiftUI

/// Punch-in zoom on a preview surface: trackpad pinch for the level, two-finger
/// scroll (momentum included) and drag for the pan, and a grab-hand cursor while
/// there is something to grab.
///
/// It hangs off `playerTopBadges`, which is the ONE mount the main player and
/// both fullscreen windows share. The pan gesture used to sit on the windowed
/// viewer surface alone, so punching in inside the fullscreen player left the
/// operator with a magnified image and no way to move it (item 19).
extension View {
    func punchInZoom() -> some View {
        modifier(PunchInZoomModifier())
    }
}

private struct PunchInZoomModifier: ViewModifier {
    @EnvironmentObject private var controller: CaptureController

    /// The surface the picture is fitted into — the pan converts pointer
    /// distance through it, so it has to be the size the renderer sees.
    @State private var viewport: CGSize = .zero
    @State private var lastTranslation: CGSize = .zero
    /// This drag is the one holding the picture — i.e. the closed hand on screen
    /// is ours to put back. A drag that never panned anything (not punched in,
    /// or a scrub that the transport took) must leave the cursor alone.
    @State private var grabbing = false

    func body(content: Content) -> some View {
        content
            // background, and hit-test-free besides: the transport bar and the
            // badges must keep every click they had before
            .background {
                GeometryReader { geo in
                    PunchEventSurface(controller: controller)
                        .onAppear { viewport = geo.size }
                        .onChange(of: geo.size) { _, size in viewport = size }
                }
            }
            // on the content, not an overlay: SwiftUI gives a child (the
            // transport, the wipe handle) priority over an ancestor's gesture
            .gesture(panGesture)
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard controller.isPunchedIn else { return }
                if !grabbing {
                    grabbing = true
                    // AppKit suppresses cursor updates while a button is down,
                    // so the closed hand set here sticks for the whole drag —
                    // once is enough, and it is not re-set per event
                    NSCursor.closedHand.set()
                }
                let delta = CGSize(
                    width: value.translation.width - lastTranslation.width,
                    height: value.translation.height - lastTranslation.height)
                lastTranslation = value.translation
                controller.panPunchIn(by: delta, viewport: viewport)
            }
            .onEnded { _ in
                lastTranslation = .zero
                if grabbing {
                    grabbing = false
                    // still magnified: back to the open hand, the operator can
                    // grab again. Zoomed out mid-drag: the arrow, because the
                    // closed hand on screen is one we put there.
                    (controller.isPunchedIn ? NSCursor.openHand : NSCursor.arrow)
                        .set()
                }
                // publish the finished pan now instead of waiting out the debounce
                controller.commitAssistDraft()
            }
    }
}

/// The AppKit half: pinch, scroll and the cursor.
private struct PunchEventSurface: NSViewRepresentable {
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
        view.onMagnify = { [weak controller] factor in
            controller?.magnifyPunchIn(by: factor)
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
    var onMagnify: ((Double) -> Void)?
    var onScroll: ((CGSize, CGSize) -> Void)?

    private var monitor: Any?
    private var trackingArea: NSTrackingArea?

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
        guard let window, event.window === window, !bounds.isEmpty,
              bounds.contains(convert(event.locationInWindow, from: nil))
        else { return event }
        switch event.type {
        case .magnify:
            // a pinch reports a RELATIVE delta per event
            onMagnify?(1 + Double(event.magnification))
            return nil
        case .scrollWheel:
            guard isPunchedIn() else { return event } // nothing to pan
            onScroll?(scrollDelta(of: event), bounds.size)
            return nil
        default:
            return event
        }
    }

    /// Scroll distance in points, in the same sense as a drag of the picture.
    private func scrollDelta(of event: NSEvent) -> CGSize {
        // a trackpad reports points; a wheel notch reports lines
        let perLine: CGFloat = 16
        let factor: CGFloat = event.hasPreciseScrollingDeltas ? 1 : perLine
        return CGSize(width: event.scrollingDeltaX * factor,
                      height: event.scrollingDeltaY * factor)
    }

    // MARK: - cursor

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        // tracking areas are geometry, not hit testing: they still fire for a
        // view that declines every click
        // mouseMoved as well as cursorUpdate: AppKit re-asserts the cursor as
        // the pointer travels, and a hand that only appears on entry is a hand
        // that vanishes the moment the operator moves
        let area = NSTrackingArea(rect: bounds,
                                  options: [.activeInActiveApp,
                                            .mouseEnteredAndExited,
                                            .mouseMoved,
                                            .cursorUpdate],
                                  owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        applyCursor()
    }

    override func mouseEntered(with event: NSEvent) {
        applyCursor()
    }

    override func mouseMoved(with event: NSEvent) {
        applyCursor()
    }

    override func mouseExited(with event: NSEvent) {
        releaseCursor()
    }

    /// Assert the grab hand — and ONLY that.
    ///
    /// `mouseMoved` fires for every pointer move inside these bounds, and the
    /// bounds are the whole player: the transport slider, the wipe handle and
    /// the badges are all inside them and set cursors of their own. Setting a
    /// cursor unconditionally from here — an arrow whenever there was nothing to
    /// grab — beat every one of them to it and flickered the pointer over the
    /// controls. So nothing is asserted unless there is something to grab.
    private func applyCursor() {
        if isPunchedIn() {
            NSCursor.openHand.set()
        } else {
            releaseCursor()
        }
    }

    /// Put the arrow back, but only over a hand.
    ///
    /// The test is what is ON SCREEN rather than a flag we kept, because the two
    /// hands have two authors: the open one here and the closed one the drag
    /// gesture sets (`PunchInZoomModifier`). A flag owned by one of them leaks
    /// the other's cursor — punch in by hotkey, drag, punch out, and the hand
    /// stays over the whole window. The cursor classes are shared singletons, so
    /// identity is the honest question to ask.
    private func releaseCursor() {
        let current = NSCursor.current
        guard current === NSCursor.openHand
                || current === NSCursor.closedHand else { return }
        NSCursor.arrow.set()
    }

    /// Never in the hit-test chain — see the type comment.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
