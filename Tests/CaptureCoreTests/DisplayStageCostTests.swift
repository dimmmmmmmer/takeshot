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
            pipeline.assistRedrawCount >= before + 40
        }, """
            \(pipeline.assistRedrawCount - before) redraws for 40 ticks — \
            if this is now fewer, the path has learnt to coalesce and this \
            test should say so instead
            """)
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
