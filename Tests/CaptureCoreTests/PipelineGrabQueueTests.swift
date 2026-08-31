import CoreVideo
import Foundation
import Testing

@testable import CaptureCore

/// **A still is rendered off the capture queue.**
///
/// `serveFrameGrab` ran a full CoreImage render and a PNG deflate inline, on
/// the queue that holds the writer, the pre-roll ring and the REC detector —
/// the one this codebase says must never be blocked. One keypress mid-take was
/// one or more dropped frames on it. The playback arm of the same feature has
/// always done it on a queue of its own.
@Suite struct PipelineGrabQueueTests {
    private func pipeline() -> CapturePipeline {
        CapturePipeline(config: .init(settings: CaptureSettings(), takeNumber: 1))
    }

    /// UHD, and that is the point: a still is rendered and deflated whole, so
    /// the cost has to be large enough to tell an inline render from a hop.
    private func frame(width: Int = 3840, height: Int = 2160) throws
        -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]]
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                            attributes as CFDictionary, &buffer)
        return try #require(buffer)
    }

    /// The render runs somewhere that is not `takeshot.pipeline`.
    @Test func theRenderDoesNotRunOnTheCaptureQueue() async throws {
        let pipeline = self.pipeline()
        let buffer = try frame()

        // Warm CoreImage first, so the measurement below is the render and not
        // the first-use cost of the framework.
        pipeline.grabNextFrame { _ in }
        pipeline.queue.sync {
            pipeline.serveFrameGrab(record: buffer, leveled: buffer)
        }
        try await Task.sleep(for: .milliseconds(800))

        // Now the one that is measured. The capture queue must be free the
        // instant `serveFrameGrab` returns; if the render were still inline,
        // this `sync` would wait behind a whole UHD render and deflate.
        // Measured as a WAIT rather than asserted on a queue label, because
        // the label is an implementation detail and the wait is the property.
        pipeline.grabNextFrame { _ in }
        let started = ContinuousClock.now
        pipeline.queue.sync {
            pipeline.serveFrameGrab(record: buffer, leveled: buffer)
        }
        let waited = ContinuousClock.now - started
        #expect(waited < .milliseconds(8), """
            serving a grab held the capture queue for \(waited) — the render \
            is inline on the queue that holds the writer, the pre-roll ring \
            and the REC detector
            """)
    }

    /// And the still still arrives.
    @Test func theStillIsStillDelivered() async throws {
        let pipeline = self.pipeline()
        let buffer = try frame()
        let delivered = DataBox()

        pipeline.grabNextFrame { png in delivered.record(png) }
        pipeline.queue.sync {
            pipeline.serveFrameGrab(record: buffer, leveled: buffer)
        }
        var waited = 0
        while delivered.value == nil, waited < 100 {
            try await Task.sleep(for: .milliseconds(20))
            waited += 1
        }
        let png = try #require(delivered.value, "the grab never came back")
        #expect(png.count > 0, "the still is empty")
        // a PNG signature, so this is a real encode and not an empty Data
        #expect(png.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
    }
}

final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data??
    func record(_ data: Data?) { lock.withLock { stored = data } }
    var value: Data? { lock.withLock { stored ?? nil } }
}
