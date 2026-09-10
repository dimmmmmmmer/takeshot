import AppKit
import Testing

@testable import TakeShotKit

/// The trace's one job is to say whether a scroll view is above the pointer,
/// and to be OFF unless it is asked for.
///
/// The monitor itself is unreachable from a test — a local `NSEvent` monitor
/// wants a real application event queue — so what is pinned here is the line it
/// prints and the switch that installs it, the same split `PunchEventView`
/// makes for the same reason.
struct WheelTraceTests {
    @Test func aRunWithoutTheVariableTracesNothing() {
        // the suite runs without it set, which is the shipped configuration
        #expect(!WheelTrace.isAsked, """
            the wheel trace is on by default — a shipped build would install \
            a monitor and print a line on every scroll
            """)
    }

    @Test func theLineNamesTheScrollerAndHowDeepItIs() {
        let found = WheelTrace.line(
            WheelTrace.Reading(window: "TakeShot",
                               point: CGPoint(x: 900, y: 300), deltaY: -3, deltaX: 0,
                               phase: "notch", precise: false,
                               scroller: WheelTrace.Scroller(
                                   document: 2000, clip: 500, offset: 0)),
            chain: ["CellHostingView", "ListTableCellView", "ListCoreClipView",
                    "ListCoreScrollView", "NSHostingView"])
        #expect(found.contains("scroller at depth 3"),
                "the line did not find the scroll view: \(found)")
        #expect(found.contains("(900,300)"))
        #expect(found.contains("notch"))
        #expect(found.contains("SCROLLABLE"),
                "the line did not say whether there was anything to scroll")
    }

    /// The case the trace exists for: the pointer is over something with no
    /// scroll view above it at all, which is the shape of every explanation
    /// the headless harness could not rule out.
    @Test func aPointerWithNoScrollerAboveItSaysSoInWords() {
        let found = WheelTrace.line(
            WheelTrace.Reading(window: "TakeShot", point: .zero, deltaY: 0,
                               deltaX: 0,
                               phase: "began", precise: true, scroller: nil),
            chain: ["DragZoneView", "NSHostingView"])
        #expect(found.contains("NO SCROLLER above the pointer"),
                "a pointer with no scroller read as fine: \(found)")
        #expect(found.contains("precise"))
    }
}
