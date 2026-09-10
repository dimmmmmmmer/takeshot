import AppKit
import SwiftUI
import Testing

@testable import TakeShotKit

/// **The panel delivers its own wheel, and claims as little as it can.**
///
/// The workaround itself is unreachable from a headless run — a local
/// `NSEvent` monitor wants a real application event queue, which is what made
/// this bug cost four rounds of instrumenting a running app to characterise.
/// What IS reachable is the pair of rules that decide what the monitor does,
/// and they are the whole of its behaviour: whether an event is the panel's,
/// and where it puts the view. Same split `PunchEventView.decide` takes, for
/// the same reason.
@Suite struct PanelWheelRelayTests {
    /// A scroll moves by exactly the delta, in the direction `scrollingDeltaY`
    /// already carries — the operator's natural-scrolling preference is baked
    /// into the event, so there is no direction decided here.
    @Test func aScrollMovesByTheDelta() {
        // 700pt of document in a 200pt window: 500 of room
        #expect(PanelWheelRelay.scrolled(offset: 100, by: -60,
                                         document: 700, clip: 200) == 160)
        #expect(PanelWheelRelay.scrolled(offset: 100, by: 60,
                                         document: 700, clip: 200) == 40)
    }

    /// **Clamped at both ends.** Past either edge the offset stops, and — the
    /// half that matters — the event stops being ours (see `claims`): eating a
    /// scroll that changes nothing is how a panel silently swallows input
    /// something else could have used.
    @Test func aScrollStopsAtBothEnds() {
        #expect(PanelWheelRelay.scrolled(offset: 10, by: 400,
                                         document: 700, clip: 200) == 0)
        #expect(PanelWheelRelay.scrolled(offset: 480, by: -400,
                                         document: 700, clip: 200) == 500)
        // a document that fits its window has no room at all
        #expect(PanelWheelRelay.scrolled(offset: 0, by: -400,
                                         document: 150, clip: 200) == 0)
    }

    /// **Continuous events only.**
    ///
    /// A legacy notch reaches the scroll view perfectly well — measured, 120
    /// points — and is none of this file's business. What is measurably lost is
    /// the continuous kind, which is what a mouse driver that turns notches
    /// into smooth pixel deltas sends, and what 886 dead events were.
    @Test func onlyAContinuousEventIsTheRelaysBusiness() {
        #expect(PanelWheelRelay.claims(precise: true, delta: -60, offset: 100,
                                       document: 700, clip: 200))
        #expect(!PanelWheelRelay.claims(precise: false, delta: -60, offset: 100,
                                        document: 700, clip: 200),
                "the relay is eating notches that already worked")
    }

    /// …and only when it would move something. Three ways it would not, and
    /// each has to hand the event back rather than consume it.
    @Test func anEventThatChangesNothingIsHandedBack() {
        // nothing to scroll
        #expect(!PanelWheelRelay.claims(precise: true, delta: -60, offset: 0,
                                        document: 150, clip: 200))
        // already at the top, scrolling further up
        #expect(!PanelWheelRelay.claims(precise: true, delta: 60, offset: 0,
                                        document: 700, clip: 200))
        // already at the bottom, scrolling further down
        #expect(!PanelWheelRelay.claims(precise: true, delta: -60, offset: 500,
                                        document: 700, clip: 200))
        // a horizontal-only gesture
        #expect(!PanelWheelRelay.claims(precise: true, delta: 0, offset: 100,
                                        document: 700, clip: 200))
    }

    /// **The panel really does tell the relay where it is.**
    ///
    /// The rules above are exercised by nothing at all if the zone never
    /// registers — the relay would be installed and inert, which looks exactly
    /// like the bug it exists for. Mounting the panel is what has to do it.
    @Test @MainActor func mountingThePanelRegistersItsRectangle() async throws {
        PanelWheelRelay.adopt(nil)
        try await ViewProbe.run { probe in
            try ViewFixtures.seedTakes(probe.controller, in: probe.root)
            await probe.mounted(TakeListView(),
                                    in: CGSize(width: 330, height: 600)) {
                #expect(PanelWheelRelay.hasZone,
                        "the panel never told the relay where it is")
            }
        }
    }

    /// …and the zone is BEHIND the panel's content, like the focus target
    /// beside it. A full-size view in front of the list is the list
    /// unreachable — the mistake `ViewPanelScrollRuleTests` was written for,
    /// and this is a second view in the same place.
    @Test func theZoneSitsBehindThePanelsContent() throws {
        let code = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/TakeShotKit/TakeListView.swift"),
            encoding: .utf8)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        #expect(code.contains(".background { PanelWheelZone() }"),
                "the wheel zone is not in a background")
        #expect(!code.contains(".overlay { PanelWheelZone() }"),
                "the wheel zone is in front of the panel's content")
    }
}
