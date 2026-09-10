import AppKit

/// **Where a scroll wheel event goes in this app — printed, on request.**
///
/// The takes panel has now been reported deaf to the wheel three times, and
/// every question a headless render can answer has been answered. Measured in
/// a real `NSWindow`, with the panel mounted five ways up to and including the
/// whole `ContentView`: the hit test under the pointer lands on the list row,
/// its ancestors run through `ListCoreScrollView`, and a `scrollWheel` handed
/// to that view scrolls it. Nothing is in front of the list, and the list is
/// willing. So the difference is in the running application — the real event,
/// the real window, or something that consumes it before either — and that is
/// not reachable from the suite.
///
/// This is the smallest thing that can answer it: a local monitor that PASSES
/// EVERY EVENT ON and only prints what it saw. It is off unless the variable
/// is set, so a shipped build installs no monitor at all.
///
/// ```
/// TAKESHOT_WHEEL_TRACE=1 /Applications/TakeShot.app/Contents/MacOS/TakeShot
/// ```
///
/// **Delete this file when the bug is closed.** It is scaffolding, and the one
/// thing worse than scaffolding is scaffolding nobody remembers is temporary.
enum WheelTrace {
    static let variable = "TAKESHOT_WHEEL_TRACE"

    static var isAsked: Bool {
        ProcessInfo.processInfo.environment[variable] == "1"
    }

    /// The monitor, kept so a second call cannot install a second one.
    @MainActor private static var token: Any?

    @MainActor
    static func startIfAsked() {
        guard isAsked, token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            MainActor.assumeIsolated { report(event) }
            // **Always.** A trace that could swallow the event would be a
            // second candidate for the bug it is here to find.
            return event
        }
        print("[wheel] tracing scroll events — set \(variable)=0 to stop")
        startTailMonitor()
    }

    /// **A second monitor, installed LAST.**
    ///
    /// Local monitors run in turn and one that returns nil DISCARDS the event —
    /// the ones after it are never called. The monitor above is installed in
    /// `applicationWillFinishLaunching`, before any view exists, so it sees
    /// every event whatever happens to it afterwards. This one is installed
    /// once the window and its views are up, so it sits behind
    /// `PunchEventView`'s — and an event the first one logs and this one never
    /// sees is an event something in between swallowed.
    ///
    /// That is the last unmeasured difference between a real wheel and the
    /// synthetic one this file hands straight to the same view, which scrolls
    /// the list 120 points.
    @MainActor
    private static func startTailMonitor() {
        let timer = Timer.scheduledTimer(withTimeInterval: 6.0, repeats: false) { _ in
            MainActor.assumeIsolated {
                tailToken = NSEvent.addLocalMonitorForEvents(
                    matching: .scrollWheel) { event in
                    MainActor.assumeIsolated {
                        tailSeen += 1
                        if tailSeen % 40 == 1 {
                            print("[tail] event \(tailSeen) survived to the last "
                                + "monitor (head \(headSeen))")
                        }
                    }
                    return event
                }
                print("[tail] last-in-line monitor armed")
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        tailTimer = timer
    }

    @MainActor private static var tailTimer: Timer?
    @MainActor private static var tailToken: Any?
    @MainActor private static var tailSeen = 0
    @MainActor private(set) static var headSeen = 0

    @MainActor
    private static func report(_ event: NSEvent) {
        headSeen += 1
        let window = event.window
        let hit = window?.contentView?.hitTest(event.locationInWindow)
        let reading = Reading(
            window: window.map { $0.title.isEmpty ? "untitled" : $0.title }
                ?? "no window",
            point: event.locationInWindow,
            deltaY: event.scrollingDeltaY,
            deltaX: event.scrollingDeltaX,
            phase: phaseName(event),
            precise: event.hasPreciseScrollingDeltas,
            scroller: scroller(above: hit).map { view in
                Scroller(
                    document: view.documentView?.frame.height ?? 0,
                    clip: view.contentView.bounds.height,
                    offset: view.contentView.bounds.origin.y)
            })
        print(line(reading, chain: chain(from: hit)))
        // **And where it ended up.**
        //
        // A local monitor runs BEFORE AppKit dispatches, so the offset above
        // is the one the event found. Reading it again on the next turn of the
        // run loop — after the scroll view has had the event — is what
        // separates the two remaining explanations: an offset still at zero is
        // a scroll view REFUSING the event, and one that moved and is back to
        // zero by the next event is a scroll view being RESET by something
        // else.
        guard let scroll = scroller(above: hit) else { return }
        detail(scroll, hit: hit)
        let before = scroll.contentView.bounds.origin.y
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let after = scroll.contentView.bounds.origin.y
                print("[after] \(String(format: "%.1f", before)) -> "
                    + "\(String(format: "%.1f", after)) "
                    + (after == before ? "REFUSED" : "MOVED"))
            }
        }
    }

    @MainActor private static var detailed = false

    /// **Everything about the scroll view that could make it refuse, once.**
    ///
    /// 886 real events measured reaching this view with 711 points of document
    /// to spare, and not one of them moved it — while a programmatic scroll to
    /// three different offsets held perfectly. So the view can scroll and will
    /// not; what is left is its own state, and the RESPONDER chain, which is
    /// what AppKit actually walks with a `scrollWheel` — the superview chain
    /// printed beside each event is only the view tree, and SwiftUI is free to
    /// point `nextResponder` somewhere else entirely.
    @MainActor
    private static func detail(_ scroll: NSScrollView, hit: NSView?) {
        guard !detailed else { return }
        detailed = true
        let clip = scroll.contentView
        print("[detail] documentRect=\(clip.documentRect) "
            + "clipBounds=\(clip.bounds) "
            + "docFrame=\(scroll.documentView?.frame ?? .zero)")
        print("[detail] vScroller=\(scroll.hasVerticalScroller) "
            + "elasticity=\(scroll.verticalScrollElasticity.rawValue) "
            + "insets=\(scroll.contentInsets) "
            + "autoInsets=\(scroll.automaticallyAdjustsContentInsets) "
            + "predominant=\(scroll.usesPredominantAxisScrolling) "
            + "scrollerStyle=\(scroll.scrollerStyle.rawValue) "
            + "hidden=\(scroll.isHidden) alpha=\(scroll.alphaValue)")
        var responders: [String] = []
        var reachesScroller = false
        var current: NSResponder? = hit
        while let step = current, responders.count < 12 {
            responders.append("\(type(of: step))")
            if step === scroll { reachesScroller = true }
            current = step.nextResponder
        }
        print("[detail] responder chain \(reachesScroller ? "REACHES" : "MISSES")"
            + " the scroller: \(responders.joined(separator: " -> "))")
    }

    /// The nearest enclosing scroll view — the one the event's own responder
    /// chain would hand `scrollWheel` to.
    @MainActor
    static func scroller(above view: NSView?) -> NSScrollView? {
        var current = view
        while let found = current {
            if let scroll = found as? NSScrollView { return scroll }
            current = found.superview
        }
        return nil
    }

    /// The view under the pointer and everything it is inside, outermost last.
    @MainActor
    static func chain(from view: NSView?) -> [String] {
        var names: [String] = []
        var current = view
        while let view = current {
            names.append("\(type(of: view))")
            current = view.superview
        }
        return names
    }

    /// What one wheel event carries that the line needs, as a value — the
    /// shape `PunchEvent` takes beside it, and for the same reason: one reading
    /// off one `NSEvent`, so a test can state only the facts a case is about.
    struct Reading {
        var window: String
        var point: CGPoint
        var deltaY: CGFloat
        var deltaX: CGFloat
        var phase: String
        var precise: Bool
        var scroller: Scroller?
    }

    /// **Whether there is anything to scroll, and whether it has moved.**
    ///
    /// The question the first trace left open. The event was measured reaching
    /// the clip view of a real scroll view, so nothing is intercepting it —
    /// which leaves two possibilities, and these three numbers separate them:
    /// a document no taller than its clip is a scroll view with nothing to
    /// scroll (the content is being cut off somewhere else), and an offset
    /// that never moves under a document that IS taller is a scroll view
    /// refusing the event.
    struct Scroller {
        var document: CGFloat
        var clip: CGFloat
        var offset: CGFloat
    }

    /// One line of the trace.
    ///
    /// Pure, and separate from the monitor for the reason `PunchEventView`'s
    /// `decide` is: a local `NSEvent` monitor cannot be driven from a test, so
    /// the only part that can be pinned is the part that is a function of what
    /// the event carried. What the line has to say is whether a SCROLL VIEW is
    /// among the pointer's ancestors — that is the whole question — so it says
    /// so in words rather than leaving it to be read out of a class list.
    static func line(_ reading: Reading, chain: [String]) -> String {
        let scroller = chain.firstIndex { $0.contains("ScrollView") }
        let verdict = scroller.map { "scroller at depth \($0)" }
            ?? "NO SCROLLER above the pointer"
        let state = reading.scroller.map {
            " doc=\(Int($0.document)) clip=\(Int($0.clip)) "
                + "offset=\(String(format: "%.1f", $0.offset)) "
                + ($0.document > $0.clip ? "SCROLLABLE" : "NOTHING-TO-SCROLL")
        } ?? ""
        return "[wheel] \(reading.window) "
            + "(\(Int(reading.point.x)),\(Int(reading.point.y))) "
            + "dy=\(String(format: "%.1f", reading.deltaY)) "
            + "dx=\(String(format: "%.1f", reading.deltaX)) \(reading.phase)"
            + "\(reading.precise ? " precise" : "") — \(verdict)\(state) — "
            + chain.prefix(6).joined(separator: " < ")
    }

    /// A wheel notch carries no phase; a trackpad's swipe carries three.
    private static func phaseName(_ event: NSEvent) -> String {
        if event.momentumPhase.contains(.changed) { return "momentum" }
        if event.phase.contains(.began) { return "began" }
        if event.phase.contains(.changed) { return "changed" }
        if event.phase.contains(.ended) { return "ended" }
        return "notch"
    }
}
