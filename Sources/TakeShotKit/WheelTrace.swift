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
    }

    @MainActor
    private static func report(_ event: NSEvent) {
        let window = event.window
        let hit = window?.contentView?.hitTest(event.locationInWindow)
        let reading = Reading(
            window: window.map { $0.title.isEmpty ? "untitled" : $0.title }
                ?? "no window",
            point: event.locationInWindow,
            deltaY: event.scrollingDeltaY,
            phase: phaseName(event),
            precise: event.hasPreciseScrollingDeltas)
        print(line(reading, chain: chain(from: hit)))
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
        var phase: String
        var precise: Bool
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
        return "[wheel] \(reading.window) "
            + "(\(Int(reading.point.x)),\(Int(reading.point.y))) "
            + "dy=\(String(format: "%.1f", reading.deltaY)) \(reading.phase)"
            + "\(reading.precise ? " precise" : "") — \(verdict) — "
            + chain.prefix(8).joined(separator: " < ")
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
