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
/// that says so rather than the comment: the pipeline's queue is parked for
/// half a second and the frame has to be on the surface before it clears.
@Suite struct PreviewReferenceSinkTests {
    @Test func presentReferenceReachesTheSurfaceWithTheCaptureQueueParked()
        async throws {
        let pipeline = PreviewProbe.makePipeline()
        let layer = MetalPreviewLayer()
        pipeline.addReferenceSink(layer)
        defer { pipeline.removeReferenceSink(layer) }

        func held() -> CVPixelBuffer? {
            layer.renderLock.lock()
            defer { layer.renderLock.unlock() }
            return layer.lastBuffer
        }
        // The attach push lands on the queue; let it settle so what this test
        // observes afterwards is its OWN frame and not that one.
        await TestWait.until({ true }, timeout: .milliseconds(50))

        let park = 0.5
        pipeline.queue.async { Thread.sleep(forTimeInterval: park) }
        let started = ContinuousClock.now
        pipeline.presentReference(PreviewProbe.frame(0xC0))
        await TestWait.until({ held() != nil }, timeout: .seconds(2))
        let elapsed = ContinuousClock.now - started

        #expect(held() != nil, "the reference frame never reached the surface")
        #expect(elapsed < .milliseconds(Int(park * 1000)), """
            the frame took \(elapsed) to appear with the capture queue parked \
            for \(park)s — it is being routed through that queue
            """)
    }
}
