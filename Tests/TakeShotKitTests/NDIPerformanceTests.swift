import CaptureCore
import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import TakeShotKit

/// What one frame costs the app on the way to an NDI source, and what it costs
/// when a second network output is up at the same time.
///
/// Opt-in, like the keyer's, the scopes' and the SRT mirror's benchmarks:
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
/// `NDIVideoMirror`). NDI's own compression, which happens inside the send, is
/// not on any of these clocks: it is behind the send, on the mirror's queue.
///
/// **The sound is the other half, and it is the one with a conversion in it.**
/// The tap produces interleaved 16-bit and NDI takes de-interleaved float, so
/// unlike the picture this leg really does touch every sample. Two numbers
/// answer what that costs: the conversion on its own, and — the one that
/// matters — what the CAPTURE QUEUE pays, which is a bounds test and a
/// `dispatch_async` and deliberately not the conversion at all.
struct NDIPerformanceTests {
    private static var enabled: Bool {
        ProcessInfo.processInfo.environment["TAKESHOT_BENCH"] != nil
    }

    /// A sender that does what the real one does to the frame and nothing else:
    /// locks it, reads the base address and the stride, unlocks. That is the
    /// whole of this path's pixel work.
    private final class LockingSender: NDISending, @unchecked Sendable {
        let sourceName = "bench"
        private let done = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var stored: UInt64 = 0

        var checksum: UInt64 { lock.withLock { stored } }

        @discardableResult
        func send(_ buffer: CVPixelBuffer, rate: NDIFrameRate) -> Bool {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            var sum: UInt64 = 0
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                // Touch one byte per row so the pass cannot be optimised away
                // and the pages are really resident, which is what the send
                // does at minimum.
                let stride = CVPixelBufferGetBytesPerRow(buffer)
                let rows = CVPixelBufferGetHeight(buffer)
                let bytes = base.assumingMemoryBound(to: UInt8.self)
                for row in 0..<rows {
                    sum &+= UInt64(bytes[row * stride])
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            lock.withLock { stored &+= sum }
            done.signal()
            return true
        }

        /// What the real audio send does to the planes and nothing else: walk
        /// them once, so the pages are resident and the pass cannot be
        /// optimised away. NDI's own compression is inside its send and is not
        /// measurable from here — the budget below is what is left for it.
        @discardableResult
        func send(audio planar: [Float], framesPerChannel: Int, channels: Int,
                  sampleRate: Int) -> Bool {
            var sum: Float = 0
            for value in planar { sum += value }
            lock.withLock { stored &+= UInt64(abs(sum)) }
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

    /// **What two outputs at once cost the DISPLAY QUEUE**, which is the only
    /// place their costs add up at all.
    ///
    /// Everything downstream is on its own queue — NDI's compression on
    /// `com.takeshot.ndi`, the H.264 encode on `com.takeshot.encode` — so the
    /// question a benchmark can answer is narrow and it is the right one: what
    /// does `wireDisplayMirrors`'s handler cost per frame with one output up
    /// against two? The answer should be one more pixel-format test and one more
    /// `dispatch_async`, and this prints both numbers so the claim is a
    /// measurement rather than an argument.
    ///
    /// Nothing is waited on here, deliberately: the point is what the CALLER
    /// pays, and a caller that waited for the send would be the bug.
    @Test(.enabled(if: NDIPerformanceTests.enabled))
    func theDisplayQueueCostOfOneOutputAgainstTwo() throws {
        let buffer = try NDIFixtures.displayBuffer(width: 1920, height: 1080)
        let sender = LockingSender()
        let mirror = NDIVideoMirror(sender: sender)
        let encoder = LiveVideoEncoder(bitsPerSecond: 8_000_000)
        let rate = NDIFrameRate(fps: 25)

        time("1080p offer, NDI alone") {
            mirror.offer(buffer, rate: rate)
        }
        time("1080p offer, encoder alone") {
            encoder.offer(buffer, framesPerSecond: 25)
        }
        time("1080p offer, both") {
            mirror.offer(buffer, rate: rate)
            encoder.offer(buffer, framesPerSecond: 25)
        }
        mirror.stop()
        encoder.stop()
    }

    // MARK: - the sound leg

    /// An identity for a tap that has no object of its own. `addAudioTap` keys
    /// on the owner, so the bare-consumer row needs something to be keyed by.
    private final class BenchOwner: @unchecked Sendable {
        static let shared = BenchOwner()
    }

    /// **The conversion on its own**: interleaved 16-bit to de-interleaved
    /// float, for one 40 ms packet, which is what arrives 25 times a second.
    ///
    /// The one piece of real per-sample work anywhere in this feature. It runs
    /// on `com.takeshot.ndi-audio` and not on the capture queue — the row below
    /// is what the capture queue actually pays — so this number is a budget
    /// question about that queue rather than about the recorder.
    @Test(.enabled(if: NDIPerformanceTests.enabled))
    func theConversionOfOnePacket() throws {
        for channels in [1, 2] {
            var cache: CMAudioFormatDescription?
            let packet: CMSampleBuffer = try #require(
                NDIAudioFixtures.signature(frames: 1920, channels: channels,
                                           cache: &cache))
            var sink = 0
            timeMicroseconds("planar float, \(channels)ch × 1920 frames",
                             runs: 200) {
                if let out = NDIAudioMirror.planarFloat(from: packet) {
                    sink &+= out.planes.count
                }
            }
            #expect(sink > 0)
        }
    }

    /// **What one audio packet costs the CAPTURE QUEUE, in the three
    /// configurations the feature has.**
    ///
    /// The audio path runs on `takeshot.pipeline` — the same serial queue the
    /// per-frame work is on — so anything added to it is taken away from the
    /// recorder. `AudioTapCostTests` is the model, and the rows here are the
    /// ones this change is answerable for:
    ///
    /// - **no NDI** — the switch off. Nothing is registered, `feedStereo`
    ///   returns before it builds a mix.
    /// - **NDI picture only** — the same code, and that is the finding rather
    ///   than a gap: the sound leg is the only thing that touches this queue,
    ///   so an NDI source's PICTURE costs the audio path exactly nothing. The
    ///   row is measured anyway, because "identical" is a measurement and
    ///   "obviously identical" is not.
    /// - **NDI picture and sound** — one mix built, and one consumer that
    ///   reads a sample count and dispatches.
    @Test(.enabled(if: NDIPerformanceTests.enabled))
    func whatOneAudioPacketCostsTheCaptureQueue() async throws {
        // No NDI: nothing registered.
        await Self.timeAudioPath("audio path, no NDI") { _ in nil }
        // NDI picture only: the video mirror exists and is not on this queue.
        await Self.timeAudioPath("audio path, NDI picture only") { _ in
            _ = NDIVideoMirror(sender: FakeNDISender(name: "bench"))
            return nil
        }
        // …and the row that ATTRIBUTES the difference: a consumer that does
        // nothing at all. The first consumer is what makes `feedStereo` build
        // the stereo mix, and the mix is the tap's cost rather than this leg's
        // — without this row the NDI leg would be charged for a
        // `selectChannels` that any transport pays.
        await Self.timeAudioPath("audio path, one no-op consumer") { pipeline in
            pipeline.addAudioTap(BenchOwner.shared) { _ in }
            return nil
        }
        // NDI picture and sound.
        await Self.timeAudioPath("audio path, NDI picture and sound") { pipeline in
            let sender = FakeNDISender(name: "bench")
            _ = NDIVideoMirror(sender: sender)
            let mirror = NDIAudioMirror(sender: sender)
            pipeline.addAudioTap(mirror) { [weak mirror] packet in
                mirror?.offer(packet)
            }
            return mirror
        }
    }

    /// …and what the FRAME path pays for the sound being up, which should be
    /// nothing: the audio leg is not a consumer of the display buffer at all.
    /// Measured rather than argued, because "not on that path" is exactly the
    /// kind of claim a later wiring change breaks silently.
    @Test(.enabled(if: NDIPerformanceTests.enabled))
    func theFramePathIsUnchangedByTheSoundLeg() throws {
        let buffer = try NDIFixtures.displayBuffer(width: 1920, height: 1080)
        let rate = NDIFrameRate(fps: 25)
        for withSound in [false, true] {
            let sender = LockingSender()
            let mirror = NDIVideoMirror(sender: sender, framesPerSecond: 100_000)
            let audio = withSound ? NDIAudioMirror(sender: sender) : nil
            let label = withSound ? "1080p frame, picture and sound"
                : "1080p frame, picture only"
            time(label) {
                mirror.offer(buffer, rate: rate)
                sender.waitForSend()
            }
            mirror.stop()
            audio?.stop()
        }
    }

    /// Push a run of packets and time the QUEUE, not the pusher.
    ///
    /// `AudioTapCostTests.time`'s shape: the packets are built up front and the
    /// barrier at the end is ordered behind every `async` before it, so what is
    /// divided is the serial queue's own occupancy. Several passes, and the
    /// MINIMUM is what to compare — the pass that got a whole core to itself.
    ///
    /// The barrier is `finishPendingWrites()`, which with no writer is exactly
    /// a `queue.async` and a continuation: the pipeline's own queue is internal
    /// to CaptureCore and this suite is one module out.
    private static func timeAudioPath(
        _ label: String, packets count: Int = 400, passes: Int = 9,
        channels: Int = 8,
        install: (CapturePipeline) -> NDIAudioMirror?) async {
        var settings = CaptureSettings()
        settings.capture.detectionMode = .vanc
        let pipeline = CapturePipeline(config: .init(
            settings: settings, slate: .empty, takeNumber: 1))
        let mirror = install(pipeline)
        defer { mirror.map { pipeline.removeAudioTap($0); $0.stop() } }

        var cache: CMAudioFormatDescription?
        var packets: [CMSampleBuffer] = []
        for index in 0..<count {
            guard let packet = NDIAudioFixtures.signature(
                frames: 1920, channels: channels, cache: &cache) else { continue }
            _ = index
            packets.append(packet)
        }
        for packet in packets.prefix(40) { pipeline.handleAudio(packet) }
        await pipeline.finishPendingWrites()

        var samples: [Double] = []
        for _ in 0..<passes {
            let start = DispatchTime.now().uptimeNanoseconds
            for packet in packets { pipeline.handleAudio(packet) }
            await pipeline.finishPendingWrites()
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start)
            samples.append(elapsed / 1000 / Double(packets.count))
        }
        samples.sort()
        print(String(format:
            "NDIAUDIOBENCH %@: min %.3f  median %.3f  max %.3f µs/packet",
            label, samples[0], samples[passes / 2], samples[passes - 1]))
    }

    /// The microsecond twin of `time`, for work too small to read in
    /// milliseconds.
    private func timeMicroseconds(_ label: String, runs: Int,
                                  _ body: () -> Void) {
        for _ in 0..<20 { body() }
        var samples: [Double] = []
        for _ in 0..<runs {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            samples.append(
                Double(DispatchTime.now().uptimeNanoseconds - start) / 1000)
        }
        samples.sort()
        print(String(format:
            "NDIAUDIOBENCH %@: min %.3f  median %.3f  max %.3f µs",
            label, samples[0], samples[runs / 2], samples[runs - 1]))
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

    /// …and the two live outputs are paced ALIKE, which is the part that is new.
    ///
    /// One display frame now feeds two consumers with independent coalescing.
    /// If their ceilings differed, a burst the display path produced would be
    /// collapsed differently by each, and two feeds of the same picture would
    /// disagree about how many frames the burst was — visible as one monitor
    /// stuttering where the other does not. Always run: it is arithmetic on two
    /// constants and there is nothing to measure.
    @Test func bothLiveOutputsSharePaceCeiling() {
        #expect(NDIVideoMirror.framesPerSecond
            == LiveVideoEncoder.framesPerSecond)
        #expect(NDIVideoMirror.minimumInterval
            == LiveVideoEncoder.minimumInterval)
        // …and they take the same pixel format, which is what makes "one display
        // frame feeds both" true rather than approximately true.
        #expect(NDIVideoMirror.acceptedPixelFormat
            == LiveVideoEncoder.acceptedPixelFormat)
    }
}
