import CoreVideo
import Foundation
import Testing

@testable import TakeShotKit

/// **What runs the compose pass**, which is the one concept the grid picture
/// needed that a rig of live boards did not.
///
/// `MultiviewComposerTests` covers the layout and the render — where each camera
/// lands, and that it lands there in pixels. This is the axis that only appeared
/// when the same composer was pointed at a sync-play comparison: several takes
/// on ONE transport rather than several boards each running a clock of its own.
/// Two of the live rule's assumptions do not survive that move, and each case
/// below is one of them.
struct MultiviewComposerPacingTests {
    /// The pacing rule, as arithmetic. The default is the live one, unchanged:
    /// camera 0 composes and nothing else does.
    @Test func theDefaultPacingIsStillTheMainCamera() {
        let live = MultiviewComposer.Pacing.clock(camera: 0)
        #expect(live.composes(on: 0))
        #expect(!live.composes(on: 1))
        #expect(!live.composes(on: 3))
        let paused = MultiviewComposer.Pacing.everyFrame
        #expect(paused.composes(on: 0))
        #expect(paused.composes(on: 3))
    }

    /// **The clock and the top-left cell are two different questions.**
    ///
    /// A multicam rig's main board is both, which is why this was one. A
    /// comparison's tiles have different lengths, so the FIRST one can freeze on
    /// its last frame while the others roll on — and a grid paced to a frozen
    /// tile stops composing while the operator watches three takes carry on. So
    /// the clock is nameable; what must NOT move with it is the layout, because
    /// the cells are what the labels on screen belong to.
    @Test func theClockCanBeATileOtherThanTheFirstAndTheLayoutStaysPut()
        async throws {
        let composed = ComposedFrames()
        let composer = MultiviewComposer { buffer, rate in
            composed.record(buffer, rate: rate)
        }
        composer.setCameraCount(2)
        composer.setPacing(.clock(camera: 1))

        // Camera 0 is not the clock any more: its frame waits, which is exactly
        // what a non-clock tile has always done.
        composer.offer(try ComposerProbe.buffer(code: 0x40, width: 320,
                                                height: 180),
                       camera: 0, framesPerSecond: 25)
        try await Task.sleep(for: .milliseconds(50))
        #expect(composed.count == 0,
                "camera 0 composed on its own after the clock moved off it")

        composer.offer(try ComposerProbe.buffer(code: 0xC0, width: 320,
                                                height: 180),
                       camera: 1, framesPerSecond: 30)
        #expect(await ControllerWait.untilWritten { composed.count > 0 },
                "the named clock composed nothing")
        let out: CVPixelBuffer = try #require(composed.latest)
        #expect(composed.rate == 30, "the rate did not follow the clock")
        // The canvas still follows camera 0 and camera 0 is still the top-left
        // cell. A clock that dragged the layout with it would put the tiles
        // under the wrong labels, which is worse than the freeze it fixes.
        #expect(CVPixelBufferGetWidth(out) == 320,
                "the canvas followed the clock instead of camera 0")
        let leftLevel: Int = ComposerProbe.level(of: out, atX: 80, y: 90)
        let rightLevel: Int = ComposerProbe.level(of: out, atX: 240, y: 90)
        #expect(leftLevel == 0x40, "camera 0 left its cell: read \(leftLevel)")
        #expect(rightLevel == 0xC0, "camera 1 read \(rightLevel)")
        composer.stop()
    }

    /// **A paused comparison has no clock, and pacing it to one leaves tiles a
    /// step behind — permanently, and invisibly.**
    ///
    /// A stepped grid delivers ONE frame per tile per step and then stops. Paced
    /// to a clock tile, every tile whose tap happened to tick after it keeps the
    /// frame from the PREVIOUS step: the compose ran when the clock arrived and
    /// nothing runs it again. The operator's own screen is right — each tile has
    /// its own layer — so the only surface that is wrong is the director's, and
    /// a frame-accurate comparison is the entire point of the mode.
    ///
    /// Driven in the order that exposes it: clock first, the other tile after.
    @Test func aPausedGridComposesOnEveryArrivalSoNoTileIsAStepBehind()
        async throws {
        let composed = ComposedFrames()
        let composer = MultiviewComposer { buffer, rate in
            composed.record(buffer, rate: rate)
        }
        composer.setCameraCount(2)
        composer.setPacing(.everyFrame)

        // the step the grid was already parked on
        composer.offer(try ComposerProbe.buffer(code: 0x20, width: 320,
                                                height: 180),
                       camera: 0, framesPerSecond: 25)
        composer.offer(try ComposerProbe.buffer(code: 0x60, width: 320,
                                                height: 180),
                       camera: 1, framesPerSecond: 25)
        #expect(await ControllerWait.untilWritten { composed.count >= 2 },
                "a paused grid composed \(composed.count) of two arrivals")

        // the step the operator just took — camera 0's tap ticks first
        composer.offer(try ComposerProbe.buffer(code: 0xA0, width: 320,
                                                height: 180),
                       camera: 0, framesPerSecond: 25)
        composer.offer(try ComposerProbe.buffer(code: 0xE0, width: 320,
                                                height: 180),
                       camera: 1, framesPerSecond: 25)
        #expect(await ControllerWait.untilWritten { composed.count >= 4 })

        let out: CVPixelBuffer = try #require(composed.latest)
        let leftLevel: Int = ComposerProbe.level(of: out, atX: 80, y: 90)
        let rightLevel: Int = ComposerProbe.level(of: out, atX: 240, y: 90)
        #expect(leftLevel == 0xA0, "camera 0 read \(leftLevel)")
        #expect(rightLevel == 0xE0,
                "the tile that ticked after the clock is a step behind: read \(rightLevel)")
        composer.stop()
    }
}
