import Foundation
import SwiftUI
import Testing

@testable import TakeShotKit

/// **At the narrowest window the divider has nothing to give.**
///
/// The two columns' floors and the window's floor are one statement, and they
/// had drifted: 1080 of window, 330 of panel, and a player column that
/// declared 680 — so the divider carried 70pt of slack at the minimum size and
/// dragging it took width the bottom bar was never measured against (owner:
/// "давай сделаем так чтобы по ширине на минимальном экране нельзя было
/// двигать размер блока тейков и другого контента – это ломает юи нав бара
/// внизу").
@Suite @MainActor struct ViewSplitFloorTests {
    @Test func theTwoFloorsFillTheNarrowestWindowExactly() {
        let total = ContentView.mainColumnMinWidth
            + ContentView.panelOuterMinWidth
        #expect(total == ContentView.windowMinWidth,
                "the divider has \(ContentView.windowMinWidth - total)pt to play with")
    }

    /// …and the panel's own floor is still inside its ceiling, or the frame
    /// would be describing an impossible column.
    @Test func thePanelsFloorIsBelowItsCeiling() {
        #expect(ContentView.panelMinWidth < ContentView.panelMaxWidth)
    }

    /// The footer is measured against the width the player column is
    /// GUARANTEED, not a number typed twice. This is the assertion that would
    /// have caught the drift.
    @Test func theFooterIsMeasuredAgainstTheGuaranteedWidth() {
        #expect(ViewBudget.mainColumnWidth == ContentView.mainColumnMinWidth)
        #expect(ViewBudget.windowMinWidth == ContentView.windowMinWidth)
        #expect(ViewBudget.panelOuterWidth == ContentView.panelOuterMinWidth)
    }

    /// A wider window still lets the divider move — a floor that locked the
    /// split everywhere would be a worse control than a slack one.
    @Test func aWiderWindowStillHasSlack() {
        let wide: CGFloat = 1600
        let slack = wide - ContentView.mainColumnMinWidth
            - ContentView.panelOuterMinWidth
        #expect(slack > 0)
        // …and the panel can take some of it, up to its ceiling.
        #expect(ContentView.panelMaxWidth > ContentView.panelMinWidth)
    }
}
