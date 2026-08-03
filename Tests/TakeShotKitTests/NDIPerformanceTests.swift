import CoreVideo
import Foundation
import Testing

@testable import TakeShotKit

/// What one frame costs the app on the way to an NDI source.
///
/// Opt-in, like the keyer's and the scopes' benchmarks:
///
///     TAKESHOT_BENCH=1 scripts/test.sh --filter NDIPerformance
///
/// and for the same reason — this suite shares a machine with whatever else is
/// building on it, so the timings assert nothing. What they print is the number
/// the budget is argued from. The MINIMUM is what to compare across builds: it
/// is the run that got a whole core to itself.
///
/// What is measured here is the APP's half: the hop onto the mirror's queue, the
/// coalesce, and handing the buffer over. There is deliberately no pixel
/// conversion to measure — NDI's uncompressed RGB is the display buffer's own
/// representation, so the sender is handed the buffer as it arrived (see
/// `NDIVideoMirror`). NDI's own compression, which happens inside the send, can
/// only be measured once the SDK headers are in place; the budget below is what
/// is left for it.
struct NDIPerformanceTests {
    private static var enabled: Bool {
        ProcessInfo.processInfo.environment["TAKESHOT_BENCH"] != nil
    }

    /// A sender that does what the real one does to the frame and nothing else:
    /// locks it, reads the base address and the stride, unlocks. That is the
    /// whole of this path's pixel work.
    private final class LockingSender: NDIVideoSending, @unchecked Sendable {
        let sourceName = "bench"
        private let done = DispatchSemaphore(value: 0)
        private(set) var checksum: UInt64 = 0

        @discardableResult
        func send(_ buffer: CVPixelBuffer, rate: NDIFrameRate) -> Bool {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                // Touch one byte per row so the pass cannot be optimised away
                // and the pages are really resident, which is what the send
                // does at minimum.
                let stride = CVPixelBufferGetBytesPerRow(buffer)
                let rows = CVPixelBufferGetHeight(buffer)
                let bytes = base.assumingMemoryBound(to: UInt8.self)
                for row in 0..<rows {
                    checksum &+= UInt64(bytes[row * stride])
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            done.signal()
            return true
        }

        func stop() {}

        /// Wait for the send this offer produced, so the timing covers the whole
        /// hop rather than only the dispatch.
        func waitForSend() {
            _ = done.wait(timeout: .now() + 1)
        }
    }

    @discardableResult
    private func time(_ label: String, runs: Int = 15,
                      _ body: () -> Void) -> Double {
        for _ in 0..<3 { body() } // warm the queue and the pool
        var samples: [Double] = []
        for _ in 0..<runs {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            samples.append(
                Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        samples.sort()
        print(String(format: "NDIBENCH %@: min %.3f ms  median %.3f ms  max %.3f ms",
                     label, samples[0], samples[runs / 2], samples[runs - 1]))
        return samples[0]
    }

    @Test(.enabled(if: NDIPerformanceTests.enabled))
    func oneFrameToTheSender() throws {
        for (label, width, height) in [("1080p", 1920, 1080),
                                       ("UHD", 3840, 2160)] {
            let sender = LockingSender()
            // No pace ceiling: the cost of one frame is the question, not the
            // rate frames are allowed at.
            let mirror = NDIVideoMirror(sender: sender, framesPerSecond: 100_000)
            let buffer = try NDIFixtures.displayBuffer(width: width,
                                                       height: height)
            time(label) {
                mirror.offer(buffer, rate: NDIFrameRate(fps: 25))
                sender.waitForSend()
            }
            mirror.stop()
        }
    }

    /// Always run, unlike the timings: the arithmetic the pace is built on.
    ///
    /// The ceiling exists for the bursts the display path can produce (an aid
    /// switched on over a paused picture, a playback scrub), not to throttle a
    /// signal — so it has to sit above every rate the app captures.
    @Test func theCeilingIsAboveEveryRateTheAppCaptures() {
        #expect(NDIVideoMirror.framesPerSecond >= 60)
        #expect(NDIVideoMirror.minimumInterval <= 1.0 / 60)
        for fps in [23.976, 24.0, 25.0, 29.97, 30.0, 50.0, 59.94, 60.0] {
            #expect(1 / fps >= NDIVideoMirror.minimumInterval,
                    "\(fps) would be throttled by the ceiling")
        }
    }
}
