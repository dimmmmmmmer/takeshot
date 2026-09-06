import CoreVideo
import Foundation
import Testing

@testable import TakeShotKit

/// Detaching the playback tap lets go of everything it held — including the
/// frames it had delivered, which used to stay resident until the NEXT attach.
/// A UHD take's last picture is tens of megabytes kept for nobody while the
/// operator is back on live.
struct PlaybackTapReleaseTests {
    private func picture() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 64, 36, kCVPixelFormatType_32BGRA,
                            nil, &buffer)
        return try #require(buffer)
    }

    @Test func detachingReleasesTheLastFrame() async throws {
        let tap = PlaybackFrameTap()
        tap.attachStill(try picture())
        var delivered = false
        for _ in 0..<100 where !delivered {
            try await Task.sleep(for: .milliseconds(20))
            delivered = tap.queue.sync { tap.lastBuffer != nil }
        }
        #expect(delivered, "the still was never delivered — nothing to release")

        tap.detach()
        #expect(tap.queue.sync { tap.lastBuffer == nil },
                "the last frame stayed resident after detach")
    }
}
