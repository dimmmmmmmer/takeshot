import AppKit
import CaptureCore
import Foundation
import SwiftUI
import Testing

@testable import TakeShotKit

/// **The burn-in arrangement at frame size** (owner: "а превью визуальное было
/// бы хорошо иметь возможность видеть крупнее, на весь экран например").
///
/// `@MainActor` because `DailiesBigPreview` is a `View` and its statics carry
/// the protocol's isolation. The runner's Swift is two releases behind this
/// Mac's and enforces that where the local one infers around it — the two-SDK
/// gap `docs/ARCHITECTURE.md` names, and the test target is the half of it the
/// local check cannot cover.
@Suite @MainActor struct ViewDailiesBigPreviewTests {
    /// The raster follows the window, so the strips are the height a frame of
    /// that size gets — a preview rendered small and stretched would be
    /// showing the wrong proportion, which is the very thing the small
    /// preview's 2x raster exists to avoid.
    @Test func theRasterFollowsTheWindow() {
        let small = DailiesBigPreview.raster(
            for: CGSize(width: 960, height: 540))
        #expect(small.height == 540)
        #expect(small.width == 960, "not 16:9: \(small)")

        let big = DailiesBigPreview.raster(
            for: CGSize(width: 2400, height: 900))
        #expect(big.height == 900)
        #expect(big.width == 1600)
    }

    /// **Capped.** Past a full 1080 there is nothing more to see and every
    /// redraw would be composing a 4K bitmap on a main-actor pass — a window
    /// dragged onto a 5K display must not cost the capture path anything.
    @Test func aHugeWindowDoesNotRenderAHugeBitmap() {
        let huge = DailiesBigPreview.raster(
            for: CGSize(width: 5120, height: 2880))
        #expect(huge.height == DailiesBigPreview.maxHeight)
        #expect(huge.width == 1920, "not 16:9 at the cap: \(huge)")
    }

    /// …and a window with no height yet (the first layout pass) still renders
    /// something rather than a zero-sized bitmap CoreGraphics refuses.
    @Test func aCollapsedWindowStillHasARaster() {
        let none = DailiesBigPreview.raster(for: .zero)
        #expect(none.height >= 180)
        #expect(none.width >= 320)
    }
}

/// The window is registered like every other one, so nothing can open a second
/// copy of it — the rule `AppWindows` exists to enforce.
@Suite struct ViewDailiesPreviewWindowTests {
    @Test func thePreviewWindowHasAnIdentityOfItsOwn() {
        #expect(AppWindowID.dailiesPreview.rawValue == "dailies-preview")
        #expect(Set(AppWindowID.allCases.map(\.rawValue)).count
            == AppWindowID.allCases.count,
                "two windows share an id, so one of them cannot be reopened")
    }
}

/// **The preview's frame is a VALUE the previews are handed**, not something
/// they read from the environment.
///
/// Not a style point: the sheet's `content` is a computed property the render
/// tests ask for directly, and an `@EnvironmentObject` reached that way does
/// not degrade — it traps, and a trap takes the whole battery down. It did.
@Suite @MainActor struct ControllerDailiesStillTests {
    @Test func theSheetOpensWithWhateverFrameTheAppAlreadyHas() async throws {
        try await ControllerHarness.run { controller, root in
            let take = ControllerFixtures.take(named: "A001C001", in: root)
            controller.takes = [take]
            // No thumbnail decoded yet: the preview falls back to flat grey
            // rather than blocking the main actor to decode one.
            controller.showDailiesSheet()
            #expect(controller.dailies.previewStill == nil)

            controller.thumbnails[take.id] = NSImage(
                size: NSSize(width: 320, height: 180))
            #expect(controller.dailiesPreviewStill == nil,
                    "an empty NSImage produced a CGImage")

            // …a real one, and the sheet picks it up when it next opens.
            let solid = NSImage(size: NSSize(width: 320, height: 180))
            solid.lockFocus()
            NSColor.green.setFill()
            NSRect(x: 0, y: 0, width: 320, height: 180).fill()
            solid.unlockFocus()
            controller.thumbnails[take.id] = solid
            controller.showDailiesSheet()
            #expect(controller.dailies.previewStill != nil,
                    "the sheet opened with no frame to lay the strips over")
        }
    }

    /// A queue whose first take has no thumbnail still finds one further down
    /// — the batch is what is being previewed, not its first item.
    @Test func aLaterTakesFrameIsUsedWhenTheFirstHasNone() async throws {
        try await ControllerHarness.run { controller, root in
            let first = ControllerFixtures.take(named: "A001C001", in: root)
            let second = ControllerFixtures.take(named: "A001C002", in: root)
            controller.takes = [first, second]
            let solid = NSImage(size: NSSize(width: 320, height: 180))
            solid.lockFocus()
            NSColor.green.setFill()
            NSRect(x: 0, y: 0, width: 320, height: 180).fill()
            solid.unlockFocus()
            controller.thumbnails[second.id] = solid
            controller.showDailiesSheet()
            #expect(controller.dailies.previewStill != nil,
                    "only the first take was asked")
        }
    }
}
