import AppKit
import CaptureCore
import SwiftUI
import Testing

@testable import TakeShotKit

/// A render pass over every view this round changed, in both languages.
///
/// The suites either side of this one ask precise questions of one view each.
/// This one asks the blunt question they cannot: does the tree still build and
/// lay out at all, in English and in Russian, at the size the app gives it. A
/// view that traps on a missing environment object, or one whose Russian labels
/// push it past the container it lives in, fails here without anyone having
/// had to predict which measurement would catch it.
@MainActor
struct ViewChangedSurfacesTests {
    /// One surface under test: what it is called in a failure, the width the
    /// app gives it, and the view itself.
    private struct Surface {
        let name: String
        let width: CGFloat
        let view: AnyView
    }

    /// The window's top chrome band, the panel readout, the panel header, the
    /// naming block, the slate row, the mode switch and an Other-content tile —
    /// every surface owner items 1, 2, 16, 27, 28, 43 and 44 touched.
    @Test func everyChangedSurfaceLaysOutInBothLanguages() async throws {
        try await ViewProbe.run { probe in
            try ViewFixtures.seedTakes(probe.controller, in: probe.root)
            let other = try ViewFixtures.seedOtherFiles(probe.controller,
                                                        in: probe.root)
            probe.controller.offloadStatus = "copying 41 of 128"

            let panel = ViewBudget.panelMinWidth
            let half = ViewBudget.footerHalfWidth
            let surfaces = [
                Surface(name: "utility buttons", width: 300,
                        view: AnyView(WindowUtilityButtons())),
                Surface(name: "panel run status", width: panel,
                        view: AnyView(PanelRunStatus())),
                Surface(name: "takes panel", width: panel,
                        view: AnyView(TakeListView())),
                Surface(name: "other content", width: panel,
                        view: AnyView(OtherContentSection())),
                Surface(name: "naming block", width: half,
                        view: AnyView(NamingFieldsView())),
                Surface(name: "slate row", width: half,
                        view: AnyView(SlateFieldsEditor(
                            scene: .constant("112A"), shot: .constant("B"),
                            takeText: .constant("4")))),
                Surface(name: "footer", width: ViewBudget.footerWidth,
                        view: AnyView(BottomBarView())),
                Surface(name: "mode switch", width: ViewBudget.playerCenterWidth,
                        view: AnyView(ViewerModeSwitch())),
                Surface(name: "other tile", width: 70,
                        view: AnyView(OtherCell(url: other[1], tileWidth: 70))),
            ]
            for surface in surfaces {
                let width = surface.width
                let laid = probe.sizes(proposedWidth: width,
                                       proposedHeight: 600) { surface.view }
                #expect(laid.en.width > 0 && laid.en.height > 0,
                        "\(surface.name) rendered as nothing")
                #expect(laid.en.width <= width + 0.5,
                        "\(surface.name) overflowed \(width)pt to \(laid.en.width)pt")
                #expect(laid.ru.width <= width + 0.5,
                        "\(surface.name) overflowed \(width)pt in Russian: \(laid.ru.width)pt")
                #expect(laid.ru.height == laid.en.height,
                        "\(surface.name) changed height with the language: \(laid)")
            }
        }
    }

    /// The main window as a whole, at the narrowest size the app allows, with
    /// the panel on either side — the composition the buttons moved INTO
    /// (owner item 2). The window may not overflow its own minimum in either
    /// language, and the top band the buttons now live in must not have pushed
    /// the player down: the column's height is the proposal, not more.
    @Test func theMainWindowStillFitsItsMinimumWithTheButtonsOnTheChrome()
        async throws {
        try await ViewProbe.run { probe in
            try ViewFixtures.seedTakes(probe.controller, in: probe.root)
            let size = CGSize(width: ViewBudget.windowMinWidth, height: 620)
            for side in ["left", "right"] {
                probe.controller.panelSide = side
                let laid = ViewRender.bothLanguages({
                    ViewRender.laidOutSize($0, in: size)
                }, { probe.hosted(ContentView()) })
                #expect(laid.en == size,
                        "the \(side)-panel window laid out at \(laid.en)")
                #expect(laid.ru == laid.en)
            }
        }
    }
}
