import CaptureCore
import Combine
import CoreGraphics
import Foundation
import Testing

@testable import TakeShotKit

/// **What a stroke over the taught REC box does, and what it costs.**
///
/// Split from `ControllerVisualRecTests`, which owns the teaching itself — the
/// two captures, what a relaunch keeps, what the bundle reports. This file is
/// the GESTURE: how far the box moves for a hand that moved that far, where a
/// drawn band stops, what a click does, and how many times any of it re-lays
/// out the window.
@MainActor
struct ControllerVisualRecBoxTests {
    // MARK: - what a drag costs the window

    /// **A drag publishes ONCE, when it settles — not sixty times a second.**
    ///
    /// `visualRecTeaching` is `@Published` on the controller, so every write
    /// fires `objectWillChange` and re-lays out every view observing it: the
    /// settings panel, the takes list, the footer. The earlier round debounced
    /// the SETTINGS write and left the publish, which is why the box and the
    /// two size sliders still dragged badly (owner: "лагают и ползунки высоты
    /// и ширины"). Counted rather than timed, for the reason
    /// `DisplayStageCostTests` counts: a publish is a publish whatever the
    /// machine, and a wall clock here would go red for unrelated reasons.
    @Test func aDragOnTheBoxPublishesOnceAndNotPerTick() async throws {
        try await ViewProbe.run { probe in
            let controller = probe.controller
            await VisualRecControllerProbe.push(controller, dot: true)
            controller.visualRecTeaching.region = VisualRecRegion(
                centerX: VisualRecControllerProbe.dotX,
                centerY: VisualRecControllerProbe.dotY)

            var publishes = 0
            let token = controller.objectWillChange.sink { _ in publishes += 1 }
            defer { token.cancel() }

            // a drag across the picture, as the gesture delivers it: the
            // translation is cumulative and the base is latched at the press
            let base = controller.liveVisualRec.region
            for step in 1...40 {
                controller.moveVisualRecRegion(
                    base, by: CGSize(width: Double(step) * 2, height: 0),
                    from: VisualRecControllerProbe.dotPoint,
                    viewport: VisualRecControllerProbe.viewport)
            }
            #expect(publishes == 0, """
                \(publishes) window-wide re-renders for 40 drag events — the \
                box is being published per tick again
                """)
            // …and the box really did move: a draft that changed nothing would
            // pass the count above for the wrong reason
            #expect(controller.liveVisualRec.region.centerX
                        > controller.visualRecTeaching.region.centerX,
                    "the drag never reached the picture")

            controller.commitVisualRecDraft()
            #expect(publishes >= 1, "the settled value was never published")
            #expect(controller.visualRecTeaching.region.centerX
                        == controller.liveVisualRec.region.centerX,
                    "the draft was not folded into the published value")
        }
    }

    /// The same for the size sliders, which take the other door into the box.
    @Test func aSizeSliderPublishesOnceAndNotPerTick() async throws {
        try await ViewProbe.run { probe in
            let controller = probe.controller
            var publishes = 0
            let token = controller.objectWillChange.sink { _ in publishes += 1 }
            defer { token.cancel() }

            for step in 1...30 {
                controller.visualRecWidth = 0.05 + Double(step) * 0.005
            }
            #expect(publishes == 0, """
                \(publishes) window-wide re-renders for 30 slider ticks
                """)
            #expect(controller.visualRecWidth > 0.05,
                    "the slider never reached the box")

            controller.commitVisualRecDraft()
            #expect(publishes >= 1)
        }
    }

    /// **The box moves by the distance the hand moved, and no further.**
    ///
    /// `DragGesture.translation` is the distance from the PRESS, re-reported on
    /// every change event, and the move added it each time: ten points arrived
    /// as 10, then 20, then 30, and the box had gone 60. It ran away from the
    /// pointer, faster the further the operator dragged (owner:
    /// "чувствительность перетаскивания маркера слишком большая").
    @Test func aDragMovesTheBoxByTheDistanceTheHandMoved() async throws {
        try await ViewProbe.run { probe in
            let controller = probe.controller
            await VisualRecControllerProbe.push(controller, dot: true)
            controller.visualRecTeaching.region = VisualRecRegion(
                centerX: 0.5, centerY: 0.5)
            let base = controller.liveVisualRec.region
            let viewport = VisualRecControllerProbe.viewport
            let start = CGPoint(x: viewport.width / 2, y: viewport.height / 2)

            // one stroke, delivered as the gesture delivers it: 160, then 320,
            // then 480 points from the press
            for step in 1...3 {
                controller.moveVisualRecRegion(
                    base, by: CGSize(width: 160.0 * Double(step), height: 0),
                    from: start, viewport: viewport)
            }

            // 480 of 1600 points across a picture that fills the viewport is
            // three tenths of the frame, and the box started at the middle
            #expect(abs(controller.liveVisualRec.region.centerX - 0.8) < 0.01, """
                the box went to \(controller.liveVisualRec.region.centerX) \
                instead of 0.8 — the drag is accumulating its own output again
                """)
        }
    }

    /// **A band drawn past the ceiling stops; it does not slide.**
    ///
    /// The box tops out at a quarter of the frame — it watches a REC dot — and
    /// a mouse crosses that easily. Centring on the band's middle meant the
    /// centre went on following the pointer after the size had saturated, so
    /// the draw became a drag exactly when the sliders hit their end, which is
    /// where the owner placed it ("потому что ползунки добегают до максимума").
    @Test func aBandDrawnPastTheCeilingStopsInsteadOfSliding() async throws {
        try await ViewProbe.run { probe in
            let controller = probe.controller
            await VisualRecControllerProbe.push(controller, dot: true)
            let viewport = VisualRecControllerProbe.viewport
            let start = CGPoint(x: 160, y: 90) // a tenth in, on the picture

            // well past the ceiling, and then further still
            controller.drawVisualRecRegion(
                from: start, to: CGPoint(x: 1200, y: 700), viewport: viewport)
            let first = controller.liveVisualRec.region
            controller.drawVisualRecRegion(
                from: start, to: CGPoint(x: 1500, y: 880), viewport: viewport)
            let second = controller.liveVisualRec.region

            #expect(first.width == VisualRecRegion.maxSize)
            #expect(second.width == VisualRecRegion.maxSize)
            #expect(second.centerX == first.centerX, """
                the box slid from \(first.centerX) to \(second.centerX) after \
                its size had saturated — a draw turning into a drag
                """)
            #expect(second.centerY == first.centerY)
            // …and it grew AWAY from the press rather than around the band
            #expect(first.centerX > 0.1, "the box did not grow from the press")
        }
    }

    /// **A click does not move the box.** A drag under the size floor is a
    /// press that has not drawn anything yet, and it used to put the box's
    /// centre under the pointer on every one of those events — so the box
    /// teleported to the press point at the start of every draw, and a bare
    /// click moved it for no reason at all (owner: "при клике на пустом
    /// пространстве в режиме рисования области он сразу туда телепортит эту
    /// область. не надо так").
    @Test func aClickOnThePictureLeavesTheBoxWhereItIs() async throws {
        try await ViewProbe.run { probe in
            let controller = probe.controller
            await VisualRecControllerProbe.push(controller, dot: true)
            controller.visualRecTeaching.region = VisualRecRegion(
                centerX: 0.5, centerY: 0.5)
            let before = controller.liveVisualRec.region

            // a click, as the drag gesture delivers one: start and end together
            controller.drawVisualRecRegion(
                from: VisualRecControllerProbe.dotPoint,
                to: VisualRecControllerProbe.dotPoint,
                viewport: VisualRecControllerProbe.viewport)

            #expect(controller.liveVisualRec.region == before,
                    "a click moved the watched box")
        }
    }

    /// A CLICK folds in whatever the drag left on screen rather than throwing
    /// it away — the rule `setAssist` follows for the aids beside this.
    @Test func aClickFoldsInTheBoxTheOperatorJustLetGoOf() async throws {
        try await ViewProbe.run { probe in
            let controller = probe.controller
            await VisualRecControllerProbe.push(controller, dot: true)
            controller.moveVisualRecRegion(
                controller.liveVisualRec.region,
                by: CGSize(width: 40, height: 0),
                from: VisualRecControllerProbe.dotPoint,
                viewport: VisualRecControllerProbe.viewport)
            let dragged = controller.liveVisualRec.region.centerX

            // a click on something else entirely
            controller.forgetVisualRecReferences()

            #expect(controller.visualRecTeaching.region.centerX == dragged, """
                the click threw away the box the operator had just dragged
                """)
        }
    }
}
