import CoreVideo
import Foundation
import Testing

@testable import TakeShotKit

/// **An idle set encodes nothing**, which is the property the whole shared-encoder
/// design is arranged around — and the one that made a test flake when it was
/// first put in, so it is worth pinning as arithmetic rather than as timing.
///
/// Nobody watching means no `VTCompressionSession` is ever created at all: not a
/// session sitting idle, not a session encoding into a sink that discards. The
/// consequence a caller has to know about is on the other side of the same
/// coin — a frame offered while nothing is subscribed is DROPPED, not held, so
/// whoever subscribes gets the next frame rather than the last one.
@Suite(.enabled(if: SRTVideoEncoder.isSupported,
                "no H.264 encoder on this machine"))
struct LiveVideoEncoderIdleTests {
    @Test func nothingIsEncodedWhileNothingIsWatching() async throws {
        let encoder = LiveVideoEncoder(bitsPerSecond: 4_000_000)
        defer { encoder.stop() }
        let buffer = try SRTFixtures.displayBuffer()
        for _ in 0..<5 {
            encoder.offer(buffer, framesPerSecond: 25)
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(!encoder.hasSinks)
        #expect(encoder.appliedBitsPerSecond == nil,
                "a session was built for nobody")
    }

    /// And the moment something IS watching, the next frame reaches it.
    @Test func theFirstFrameAfterASinkArrivesReachesIt() async throws {
        let encoder = LiveVideoEncoder(bitsPerSecond: 4_000_000)
        defer { encoder.stop() }
        let samples = SampleCounter()
        encoder.addSink(samples) { _ in samples.count() }
        let buffer = try SRTFixtures.displayBuffer()
        let deadline = Date().addingTimeInterval(5)
        while samples.total == 0, Date() < deadline {
            encoder.offer(buffer, framesPerSecond: 25)
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(samples.total > 0, "a subscribed sink got nothing")
        #expect(encoder.appliedBitsPerSecond == 4_000_000)
    }
}

/// Samples that reached a sink. Its identity is the sink's key, so it is a
/// class; the count is touched from VideoToolbox's thread, so it is locked.
final class SampleCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    func count() { lock.withLock { stored += 1 } }
    var total: Int { lock.withLock { stored } }
}
