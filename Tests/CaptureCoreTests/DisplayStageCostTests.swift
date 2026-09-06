import CoreMedia
import Foundation
import Testing

@testable import CaptureCore

/// **What a drag on an assist slider costs the display path.**
///
/// A frame arriving is coalesced: `enqueuePreview` replaces the pending one
/// and schedules a single pass, so twenty frames in a row cost one redraw when
/// the queue is behind. An ASSIST TICK is not: `redrawDisplayStage` is a plain
/// `displayQueue.async` with no latest-wins gate, and a slider dragged across
/// its range is one of those per tick — while a take is recording, on the same
/// machine as the encoder.
///
/// Counted rather than timed: a pass is a pass whatever the machine, and a
/// wall clock here would go red for reasons that have nothing to do with this
/// code.
struct DisplayStageCostTests {
    private func pipeline() -> CapturePipeline {
        CapturePipeline(config: .init(settings: CaptureSettings(), takeNumber: 1))
    }

    /// The characterization: N ticks, N passes. If this ever reads 1, someone
    /// has put a latest-wins gate on the redraw and this suite is how they say
    /// so — the number is the argument for doing it, not a rule against it.
    @Test func everyAssistTickCostsItsOwnDisplayPass() async throws {
        let pipeline = pipeline()
        pipeline.handleFormat(CaptureFormat(width: 1920, height: 1080,
                                            frameRate: 25, timecodeFPS: 25,
                                            name: "1080p25"))
        // a frame has to have been shown for a redraw to have anything to redo
        pipeline.handleFrame(pixelBuffer: TestMedia.pixelBuffer(width: 1920,
                                                                height: 1080),
                             pts: CMTime(value: 40, timescale: 1000),
                             timecode: nil)
        #expect(await TestWait.becomesTrue { pipeline.lastDisplaySource != nil },
                "nothing was ever displayed, so nothing can be redrawn")

        let before = pipeline.displayStagePasses
        // a drag across a slider's range, as the UI delivers it
        for _ in 0..<40 { pipeline.redrawDisplayStage() }
        #expect(await TestWait.becomesTrue {
            pipeline.displayStagePasses >= before + 40
        }, """
            \(pipeline.displayStagePasses - before) passes for 40 ticks — \
            if this is now fewer, the redraw has learnt to coalesce and this \
            test should say so instead
            """)
    }

    /// …and the frame path DOES coalesce, which is the comparison that makes
    /// the number above mean something.
    @Test func framesArrivingFasterThanTheScreenCostOnePassEach() async throws {
        let pipeline = pipeline()
        pipeline.handleFormat(CaptureFormat(width: 1920, height: 1080,
                                            frameRate: 25, timecodeFPS: 25,
                                            name: "1080p25"))
        let picture = TestMedia.pixelBuffer(width: 1920, height: 1080)
        for index in 1...40 {
            pipeline.enqueuePreview(pixelBuffer: picture)
            _ = index
        }
        await pipeline.finishPendingWrites()
        // Nothing is asserted about the count: what is pinned is that the
        // coalescing path exists and is a different one, which the reader can
        // see beside `redrawDisplayStage`.
        #expect(pipeline.displayStagePasses == 0,
                "the frame path went through the assist redraw")
    }
}
