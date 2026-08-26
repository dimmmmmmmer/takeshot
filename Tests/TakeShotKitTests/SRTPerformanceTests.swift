import CoreVideo
import Foundation
import Testing

@testable import TakeShotKit

/// What one frame costs the app on the way to an SRT link.
///
/// Opt-in, like the keyer's, the scopes' and the multiview's benchmarks:
///
///     TAKESHOT_BENCH=1 scripts/test.sh --filter SRTPerformance
///
/// and for the same reason — this suite shares a machine with whatever else is
/// building on it, so the timings assert nothing. What they print is the number the
/// budget is argued from. The MINIMUM is what to compare across builds: it is the
/// run that got a whole core to itself.
///
/// **What is measured, and why it is the number that matters.** The NDI output this
/// replaced cost 0.114 ms a frame at 1080p because there was nothing to do — its
/// uncompressed RGB was the display buffer, handed over uncopied. An H.264 encode
/// plus an MPEG-TS mux is not that, and the honest thing to do is measure it rather
/// than claim it is small. What the number is NOT is a cost to the frame path:
/// every millisecond below is spent on `com.takeshot.srt`, and the display queue's
/// whole involvement is a pixel-format test and one `dispatch_async`.
///
/// Measured in RELEASE on an M-series laptop, which is what the numbers quoted in
/// docs/ARCHITECTURE.md are: offer, under 0.001 ms at 1080p and at UHD; offer to
/// first datagram out, 6.10 ms at 1080p and 20.9 ms at UHD; the mux alone,
/// 0.046 ms for a 40 KB frame. Debug roughly halves the first two and costs the
/// mux eight times as much, which is what a byte loop with bounds checks does.
@Suite(.enabled(if: SRTVideoEncoder.isSupported,
                "no H.264 encoder on this machine"))
struct SRTPerformanceTests {
    private static var timed: Bool {
        ProcessInfo.processInfo.environment["TAKESHOT_BENCH"] != nil
    }

    /// A link that counts the bytes and does nothing else — the whole of what is
    /// left once the encode and the mux are done.
    private final class CountingStream: SRTStreamSending, @unchecked Sendable {
        private let lock = NSLock()
        private var storedBytes = 0
        private var armed = false
        private let done = DispatchSemaphore(value: 0)

        func open() throws {}

        func send(_ datagram: Data) -> SRTSendOutcome {
            let first: Bool = lock.withLock {
                storedBytes += datagram.count
                guard armed else { return false }
                armed = false
                return true
            }
            if first { done.signal() }
            return .sent
        }

        var lastSendError: String? { nil }
        func close() {}

        var bytes: Int { lock.withLock { storedBytes } }

        /// Arm, then wait for the FIRST datagram after arming.
        ///
        /// A plain counting semaphore is wrong here and measurably so: one UHD
        /// frame is over a hundred datagrams, so a `signal` per datagram leaves a
        /// hundred credits behind and the next wait returns instantly. That
        /// produced a 0.038 ms "minimum" for a frame that takes twenty.
        func arm() {
            lock.withLock { armed = true }
        }

        func waitForFrame() {
            _ = done.wait(timeout: .now() + 5)
        }
    }

    @discardableResult
    private func time(_ label: String, runs: Int = 25,
                      _ body: () -> Void) -> Double {
        for _ in 0..<5 { body() } // warm the queue, the pool and the encoder
        var samples: [Double] = []
        for _ in 0..<runs {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            samples.append(
                Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        samples.sort()
        print(String(format: "SRTBENCH %@: min %.3f ms  median %.3f ms  max %.3f ms",
                     label, samples[0], samples[runs / 2], samples[runs - 1]))
        return samples[0]
    }

    /// A mirror over a counting link, with no pace ceiling: the cost of one frame
    /// is the question, not the rate frames are allowed at.
    private func rig(_ stream: CountingStream) -> SRTRig {
        let encoder = LiveVideoEncoder(bitsPerSecond: 8_000_000,
                                       framesPerSecond: 100_000)
        let rig = SRTRig(
            encoder: encoder,
            mirror: SRTVideoMirror(endpoint: SRTFixtures.endpoint,
                                   encoder: encoder, factory: { _ in stream },
                                   onEvent: { _ in }))
        rig.start()
        return rig
    }

    /// **What the DISPLAY QUEUE pays, which is the number that matters.**
    ///
    /// This is the one directly comparable to the 0.114 ms the NDI output cost at
    /// 1080p, and it is the whole of what the frame path gives up for this
    /// feature: a pixel-format test and one `dispatch_async`. Everything else
    /// below happens on `com.takeshot.srt`.
    @Test(.enabled(if: SRTPerformanceTests.timed))
    func whatTheDisplayQueuePays() throws {
        for (label, width, height) in [("1080p offer", 1920, 1080),
                                       ("UHD offer", 3840, 2160)] {
            let stream = CountingStream()
            let mirror = rig(stream)
            let buffer = try SRTFixtures.displayBuffer(width: width,
                                                       height: height)
            time(label, runs: 200) { mirror.offer(buffer, framesPerSecond: 25) }
            mirror.stop()
        }
    }

    /// Offer to first datagram out: the queue hop, the H.264 encode and the mux.
    /// A LATENCY rather than an occupancy — VideoToolbox's encode is asynchronous,
    /// so the mirror's queue is free again long before this number elapses.
    @Test(.enabled(if: SRTPerformanceTests.timed))
    func oneFrameToTheLink() throws {
        for (label, width, height) in [("1080p", 1920, 1080),
                                       ("UHD", 3840, 2160)] {
            let stream = CountingStream()
            let mirror = rig(stream)
            let buffer = try SRTFixtures.displayBuffer(width: width,
                                                       height: height)
            time(label) {
                stream.arm()
                mirror.offer(buffer, framesPerSecond: 25)
                stream.waitForFrame()
            }
            mirror.stop()
        }
    }

    /// The MUX alone, with the encode taken out of it — 40 KB of payload, which is
    /// one 1080p frame at 8 Mbit/s and 25 fps. Separated because the two halves have
    /// completely different characters: one is silicon and one is a byte loop.
    @Test(.enabled(if: SRTPerformanceTests.timed))
    func oneFrameThroughTheMuxer() {
        for (label, bytes) in [("40 KB (1080p at 8 Mbit/s)", 40_000),
                               ("160 KB (a keyframe)", 160_000)] {
            var muxer = MPEGTSMuxer()
            let unit = MPEGTSFixtures.unit(bytes: bytes, keyframe: true)
            time(label) { _ = muxer.datagrams(for: unit) }
        }
    }

    /// **Always run, unlike the timings: the byte arithmetic the link budget rests
    /// on.**
    ///
    /// A wall-clock assertion would pin the runner rather than the app. A byte
    /// count is a property of the format, and it is the one an operator's bitrate
    /// setting is spent against: the transport's own overhead has to be a few
    /// percent, not a third.
    @Test func theTransportOverheadIsAFewPercentOfThePayload() {
        var muxer = MPEGTSMuxer()
        // One second of 1080p at 8 Mbit/s: 25 frames, one of them a keyframe
        // roughly four times the size of an inter frame.
        var payload = 0
        var wire = 0
        for frame in 0..<25 {
            let keyframe = frame == 0
            let bytes = keyframe ? 100_000 : 25_000
            payload += bytes
            wire += muxer.datagrams(
                for: MPEGTSFixtures.unit(bytes: bytes,
                                         pts: Int64(frame) * 3600,
                                         keyframe: keyframe))
                .reduce(0) { $0 + $1.count }
        }
        let overhead = Double(wire - payload) / Double(payload)
        #expect(overhead > 0, "the wire cannot be smaller than the payload")
        #expect(overhead < 0.06,
                "the transport costs \(Int(overhead * 100))% on top of the payload")
        // …and every byte of it is in whole datagrams, which is what the socket
        // was configured for.
        #expect(wire % MPEGTSMuxer.datagramLength == 0,
                "\(wire) bytes is not a whole number of 1316-byte datagrams")
    }

    /// The count of datagrams a second of video costs, derived rather than
    /// measured — this is what a bitrate setting turns into on the wire.
    @Test func aSecondOfVideoIsTheDatagramCountTheBitrateImplies() {
        var muxer = MPEGTSMuxer()
        var datagrams = 0
        for frame in 0..<25 {
            datagrams += muxer.datagrams(
                for: MPEGTSFixtures.unit(bytes: 40_000,
                                         pts: Int64(frame) * 3600)).count
        }
        // 40 KB of payload plus a 14-byte PES header is 218 packets: one at 176
        // bytes and 217 at 184. That is 32 datagrams once it is rounded up to
        // sevens, and 25 frames of it is 800.
        #expect(datagrams == 800,
                "a second of 8 Mbit/s video came to \(datagrams) datagrams")
        // 800 x 1316 bytes a second is 8.4 Mbit/s of UDP payload for an 8 Mbit/s
        // picture. The gap is the transport plus the null-packet padding, and it
        // is the number to hand somebody asking what to reserve on a link.
        let bits = 800 * MPEGTSMuxer.datagramLength * 8
        #expect(bits == 8_422_400)
    }
}
