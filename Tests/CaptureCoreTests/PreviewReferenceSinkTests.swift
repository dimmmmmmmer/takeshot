import CoreImage
import CoreVideo
import Foundation
import Testing

@testable import CaptureCore

/// **The A/B pane can be painted without the capture queue.**
///
/// A pinned still reaches the reference surfaces through `publishReference`,
/// which runs on the pipeline's own queue — right, because that queue owns the
/// pin. A reference that PLAYS produces a frame per frame on another engine's
/// decode queue, and routing those through the capture queue would put a decode
/// in front of the queue that appends to the writer: not a late picture, a hole
/// in the file (`LUTPathCostTests`' own words).
///
/// So `presentReference` presents from the CALLER's queue, and this is the test
/// that says so rather than the comment: the pipeline's queue is parked and the
/// frame has to be on the surface before it clears.
@Suite struct PreviewReferenceSinkTests {
    /// What a surface is holding, read the way the renderer writes it —
    /// `lastBuffer` is written on the redraw queue under `renderLock`, and a
    /// bare read is the data race ThreadSanitizer reports in the test.
    private func held(_ layer: MetalPreviewLayer) -> CVPixelBuffer? {
        layer.renderLock.lock()
        defer { layer.renderLock.unlock() }
        return layer.lastBuffer
    }

    /// **The attach push, LANDED** — both halves of it.
    ///
    /// `addReferenceSink` hands the surface its first frame on the pipeline
    /// queue, and the surface draws it on its own redraw queue, so a test that
    /// wants to say what is on screen has to drain both. Draining is also the
    /// only way to keep that push from arriving in the middle of what a test
    /// does next: with nothing pinned it is `clearToBlack`, which sets
    /// `lastBuffer` back to nil and would wipe a frame presented before it got
    /// there.
    private func settle(_ pipeline: CapturePipeline,
                        _ layer: MetalPreviewLayer) {
        pipeline.queue.sync {}
        layer.redrawQueue.sync {}
    }

    @Test func presentReferenceReachesTheSurfaceWithTheCaptureQueueParked()
        async throws {
        let pipeline = PreviewProbe.makePipeline()
        let layer = MetalPreviewLayer()
        pipeline.addReferenceSink(layer)
        defer { pipeline.removeReferenceSink(layer) }

        // The attach push settled BEFORE anything else happens, so what this
        // test observes afterwards is its own frame and not that one. It used
        // to ask `TestWait.until({ true })` for 50 ms, which returns on its
        // first poll and therefore waits for nothing at all: green here every
        // time and a coin toss on the runner — the same commit passed this
        // test under ThreadSanitizer and failed it under coverage, with
        // `lastBuffer` nil after the full wait because the attach's
        // `clearToBlack` had landed on the redraw queue AFTER the frame.
        settle(pipeline, layer)
        try #require(held(layer) == nil,
                     "nothing is pinned — the attach push should have blanked")

        let park = 1.0
        pipeline.queue.async { Thread.sleep(forTimeInterval: park) }
        let started = ContinuousClock.now
        pipeline.presentReference(PreviewProbe.frame(0xC0))
        await TestWait.until({ held(layer) != nil }, timeout: .seconds(3))
        let elapsed = ContinuousClock.now - started

        #expect(held(layer) != nil, "the reference frame never reached the surface")
        #expect(elapsed < .milliseconds(Int(park * 1000)), """
            the frame took \(elapsed) to appear with the capture queue parked \
            for \(park)s — it is being routed through that queue
            """)
    }

    /// **A surface joining mid-play is handed the frame the compositor would
    /// use, not the still underneath it.**
    ///
    /// The attach push used to hand over `previewReference` — the pin — and a
    /// moving reference is not that buffer. Freeze a reference clip on a frame
    /// and then open the A/B pane: the pane showed the frame that was PINNED
    /// rather than the one the operator froze on, and with the clip standing
    /// still nothing ever came along to correct it. It asks
    /// `currentReferenceFrame` now, which is the expression
    /// `presentProcessedFrame` reads per frame, so the pane and the composite
    /// cannot disagree about what the reference IS.
    @Test func attachingASurfaceShowsTheMovingReferenceAndNotThePin()
        async throws {
        let pipeline = PreviewProbe.makePipeline()
        pipeline.setPreviewReference(buffer: PreviewProbe.frame(0x20))
        let moving = PreviewProbe.frame(0xC0)
        pipeline.setReferenceFrameProvider { moving }
        defer { pipeline.setReferenceFrameProvider(nil) }

        let layer = MetalPreviewLayer()
        pipeline.addReferenceSink(layer)
        defer { pipeline.removeReferenceSink(layer) }
        settle(pipeline, layer)

        let shown = try #require(held(layer),
                                 "the surface was handed nothing at all")
        #expect(PreviewProbe.level(of: shown) == 0xC0, """
            the surface shows \(PreviewProbe.level(of: shown)) — that is the \
            pinned still, not the reference clip's current frame
            """)
    }
}
