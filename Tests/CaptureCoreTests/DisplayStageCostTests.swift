import CoreMedia
import Foundation
import Testing

@testable import CaptureCore

/// **What a drag on an assist slider costs the display path.**
///
/// A frame arriving is coalesced: `enqueuePreview` replaces the pending one and
/// schedules a single pass, so twenty frames in a row cost one redraw when the
/// queue is behind. An ASSIST TICK was NOT — `redrawDisplayStage` was a plain
/// `displayQueue.async`, and a slider dragged across its range is one of those
/// per tick, about sixty a second, each a full display pass at the signal's
/// raster while a take is recording on the same machine as the encoder.
///
/// This suite was written to characterize that, and said so: "if this ever
/// reads 1, someone has put a latest-wins gate on the redraw and this suite is
/// how they say so." Somebody did, because the owner felt it — "лагает action
/// safe, title safe", "лагают и ползунки высоты и ширины" — so the suite says
/// so.
///
/// Counted rather than timed: a pass is a pass whatever the machine, and a
/// wall clock here would go red for reasons that have nothing to do with this
/// code.
struct DisplayStageCostTests {
    private func pipeline() -> CapturePipeline {
        CapturePipeline(config: .init(settings: CaptureSettings(), takeNumber: 1))
    }

    /// **Forty ticks, at most two passes.**
    ///
    /// Two and not one: the flag is cleared at the START of a pass, so a change
    /// arriving while one is rendering schedules exactly one more — which is
    /// what guarantees the value the operator settled on is the one that lands.
    /// A gate that cleared the flag at the END would coalesce to one pass and
    /// could finish on a stale value, which is the trade this shape refuses.
    @Test func aDragCostsAtMostTwoDisplayPasses() async throws {
        let pipeline = pipeline()
        pipeline.handleFormat(CaptureFormat(width: 1920, height: 1080,
                                            frameRate: 25, timecodeFPS: 25,
                                            name: "1080p25"))
        // A frame has to have been shown for a redraw to have anything to
        // redo. Waited on through the COUNTER and not through
        // `lastDisplaySource`, which belongs to the display queue: reading it
        // from here is a data race, and ThreadSanitizer said so about the
        // first version of this test.
        pipeline.handleFrame(pixelBuffer: TestMedia.pixelBuffer(width: 1920,
                                                                height: 1080),
                             pts: CMTime(value: 40, timescale: 1000),
                             timecode: nil)
        #expect(await TestWait.becomesTrue { pipeline.displayStagePasses > 0 },
                "nothing was ever displayed, so nothing can be redrawn")

        let before = pipeline.assistRedrawCount
        // a drag across a slider's range, as the UI delivers it
        for _ in 0..<40 { pipeline.redrawDisplayStage() }
        #expect(await TestWait.becomesTrue {
            pipeline.assistRedrawCount > before
        }, "the drag redrew nothing at all")
        await pipeline.finishPendingWrites()
        pipeline.settleDisplay()
        let drawn = pipeline.assistRedrawCount - before
        #expect(drawn <= 2, """
            \(drawn) passes for 40 ticks — the latest-wins gate in \
            redrawDisplayStage is not doing anything, and a drag is sixty of \
            these a second at the signal's raster
            """)

        // …and the LAST value still lands: a gate that dropped the final tick
        // would leave the picture showing an aid the operator dragged past.
        let settled = pipeline.assistRedrawCount
        pipeline.redrawDisplayStage()
        #expect(await TestWait.becomesTrue {
            pipeline.assistRedrawCount > settled
        }, "a redraw after the drag never ran, so the last value never landed")
    }

    /// …and the frame path DOES coalesce, which is the comparison that makes
    /// the number above mean something: forty frames offered faster than the
    /// screen takes them cost fewer than forty passes.
    @Test func framesArrivingFasterThanTheScreenAreCoalesced() async throws {
        let pipeline = pipeline()
        pipeline.handleFormat(CaptureFormat(width: 1920, height: 1080,
                                            frameRate: 25, timecodeFPS: 25,
                                            name: "1080p25"))
        let picture = TestMedia.pixelBuffer(width: 1920, height: 1080)
        for _ in 0..<40 { pipeline.enqueuePreview(pixelBuffer: picture) }
        await pipeline.finishPendingWrites()
        #expect(pipeline.assistRedrawCount == 0,
                "the frame path went through the assist redraw")
        #expect(pipeline.displayStagePasses < 40,
                """
                40 frames cost \(pipeline.displayStagePasses) passes — the \
                latest-wins gate in enqueuePreview is not doing anything
                """)
    }
}
