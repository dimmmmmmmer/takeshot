import CoreVideo
import Foundation
import Testing

@testable import CaptureCore

/// **What the choice costs the FRAME PATH**, measured on the display queue's
/// own function rather than argued about.
///
/// The claim the whole design rests on is that a browser choosing a picture
/// cannot slow the machine down that is writing ProRes to a card. Two numbers
/// say whether that is true, and only the first is a fact about this app rather
/// than about VideoToolbox:
///
/// - **Nobody watching.** `publishDisplayFrame` returns before it builds a
///   `LiveFrame` at all, so an idle app pays two locked reads of a nil.
/// - **One consumer, two consumers.** The fan-out is a `LiveFrame` (two class
///   references, no allocation), a subscript, and one call per consumer. What
///   each consumer then does with the buffer is its own queue's problem — the
///   encoders `dispatch_async` and return.
///
/// The timings are opt-in, like the keyer's, the scopes' and the multiview's:
///
///     TAKESHOT_BENCH=1 scripts/test.sh --filter LivePicturePath
///
/// and for the same reason — this suite shares a machine with whatever else is
/// building on it, so nothing here asserts on a clock. The MINIMUM is what to
/// compare across builds, being the run that got a whole core to itself.
struct LivePicturePathTests {
    private static var timed: Bool {
        ProcessInfo.processInfo.environment["TAKESHOT_BENCH"] != nil
    }

    /// A recorder that does what a real consumer does on this queue and no
    /// more: name a picture, take the buffer, return.
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = 0
        private var last: CVPixelBuffer?
        let picture: LivePicture

        init(_ picture: LivePicture) { self.picture = picture }

        func take(_ frame: LiveFrame) {
            let buffer = frame[picture]
            lock.withLock {
                stored += 1
                last = buffer
            }
        }

        var count: Int { lock.withLock { stored } }
        var latest: CVPixelBuffer? { lock.withLock { last } }
    }

    @discardableResult
    private func time(_ label: String, runs: Int = 2000,
                      _ body: () -> Void) -> Double {
        for _ in 0..<200 { body() }
        var samples: [Double] = []
        for _ in 0..<runs {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            samples.append(
                Double(DispatchTime.now().uptimeNanoseconds - start) / 1000)
        }
        samples.sort()
        print(String(format: "LIVEPICTUREBENCH %@: min %.3f µs  median %.3f µs  max %.3f µs",
                     label, samples[0], samples[runs / 2], samples[runs - 1]))
        return samples[0]
    }

    /// The per-frame cost at zero, one and two consumers.
    ///
    /// Driven through `publishDisplayFrame` itself — the display queue's own
    /// entry point, with the chroma key and the assist stage idle, which is
    /// what an app with no aids switched on actually runs.
    @Test(.enabled(if: LivePicturePathTests.timed))
    func theFanOutCostPerFrame() {
        let pipeline = PreviewProbe.makePipeline()
        let decorated = PreviewProbe.frame(0x40)
        let clean = PreviewProbe.frame(0x80)

        time("nobody watching") {
            pipeline.publishDisplayFrame(decorated, clean: clean, deadline: .max)
        }

        let one = Sink(.decorated)
        pipeline.setOnDisplayFrame { one.take($0) }
        time("one picture (decorated)") {
            pipeline.publishDisplayFrame(decorated, clean: clean, deadline: .max)
        }

        let other = Sink(.clean)
        pipeline.setOnMonitorFrame { other.take($0) }
        time("two pictures (decorated + clean)") {
            pipeline.publishDisplayFrame(decorated, clean: clean, deadline: .max)
        }
        pipeline.setOnDisplayFrame(nil)
        pipeline.setOnMonitorFrame(nil)
    }

    /// **Always run, unlike the timings**: with nothing watching, nothing is
    /// handed anywhere at all.
    ///
    /// This is the structural half of the number above, and it is the one that
    /// could regress silently — a slot left installed after the last viewer
    /// leaves looks exactly like an idle app from outside, and pays a closure
    /// call and a `LiveFrame` per frame for the rest of the shift.
    @Test func anIdleAppHandsTheFrameNowhere() {
        let pipeline = PreviewProbe.makePipeline()
        #expect(!pipeline.publishesDisplayFrames)
        #expect(!pipeline.publishesMonitorFrames)

        let watcher = Sink(.decorated)
        pipeline.setOnDisplayFrame { watcher.take($0) }
        #expect(pipeline.publishesDisplayFrames)
        pipeline.publishDisplayFrame(PreviewProbe.frame(0x40),
                                     clean: PreviewProbe.frame(0x80),
                                     deadline: .max)
        #expect(watcher.count == 1)

        pipeline.setOnDisplayFrame(nil)
        #expect(!pipeline.publishesDisplayFrames)
        pipeline.publishDisplayFrame(PreviewProbe.frame(0x40),
                                     clean: PreviewProbe.frame(0x80),
                                     deadline: .max)
        #expect(watcher.count == 1,
                "a frame reached a consumer that had gone")
    }

    /// **Two consumers of two different pictures are served from ONE publish.**
    ///
    /// The alternative shape — a second pass over the frame per picture — is
    /// what this design exists to avoid, and the thing that would show it is
    /// each consumer getting the buffer the OTHER one asked for. Identity, so a
    /// copy anywhere in the fan-out fails here.
    @Test func onePublishServesTwoPicturesWithoutCopyingEither() {
        let pipeline = PreviewProbe.makePipeline()
        let mirror = Sink(.decorated)
        let monitor = Sink(.clean)
        pipeline.setOnDisplayFrame { mirror.take($0) }
        pipeline.setOnMonitorFrame { monitor.take($0) }
        defer {
            pipeline.setOnDisplayFrame(nil)
            pipeline.setOnMonitorFrame(nil)
        }
        let decorated = PreviewProbe.frame(0x40)
        let clean = PreviewProbe.frame(0x80)
        pipeline.publishDisplayFrame(decorated, clean: clean, deadline: .max)

        #expect(mirror.latest === decorated)
        #expect(monitor.latest === clean)
        // And the grid takes the same buffer the clean picture does, which is
        // what stops it from being a second reading of what clean means.
        let grid = Sink(.grid)
        pipeline.setOnMonitorFrame { grid.take($0) }
        pipeline.publishDisplayFrame(decorated, clean: clean, deadline: .max)
        #expect(grid.latest === clean)
    }
}
