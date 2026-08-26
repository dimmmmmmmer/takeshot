import CoreMedia
import Foundation
import Testing

@testable import CaptureCore

/// **What the tap costs the capture queue: nothing listening, one transport,
/// two.**
///
/// The audio path runs on `takeshot.pipeline` — the same serial queue the
/// per-frame work is on — so anything added to it is taken away from the
/// recorder. Two things are checked here and they are different kinds of claim.
///
/// The first is STRUCTURAL and always runs: with nothing listening no mix is
/// built at all, observed at the format cache rather than at a clock. A cache
/// that is still nil after thirty packets is proof the `selectChannels` call
/// was never reached, and unlike a timing it cannot be true on a fast machine
/// and false on a loaded one.
///
/// The second is the TIMING, opt-in like every other benchmark in this suite:
///
///     TAKESHOT_BENCH=1 scripts/test.sh --filter AudioTapCost
///
/// It asserts nothing — it shares a machine with whatever else is building on
/// it — and prints the number the budget is argued from. The MINIMUM is what to
/// compare across builds: it is the run that got a whole core to itself.
struct AudioTapCostTests {
    private static var timed: Bool {
        ProcessInfo.processInfo.environment["TAKESHOT_BENCH"] != nil
    }

    /// Eight channels, so the stereo fold is a real re-interleave.
    ///
    /// Deliberately not two: `PCMAudio.selectChannels` hands back the original
    /// buffer when every channel is selected, so a stereo SOURCE would build no
    /// mix and touch no cache even with a tap on — and the test below would
    /// then pass for a reason that has nothing to do with the guard.
    static let channels = 8

    /// **Nothing listening builds no mix.**
    ///
    /// `stereoFormatCache` is written by the one `PCMAudio.selectChannels` call
    /// in `feedStereo` and by nothing else, so it being nil after a run of
    /// packets is the guard having returned every time. Removing that guard
    /// turns this red without any clock being involved.
    @Test func nothingListeningBuildsNoMix() throws {
        let pipeline = AudioTapFixture.idlePipeline()
        try AudioTapFixture.push(30, channels: Self.channels, into: pipeline)
        #expect(pipeline.queue.sync { pipeline.stereoFormatCache } == nil,
                "a stereo mix was built with nobody listening")
    }

    /// …and one listener does. The other half of the same observation: a test
    /// that only checked the nil would pass on a pipeline whose tap never fires
    /// at all.
    @Test func oneListenerBuildsExactlyOneMixPerPacket() throws {
        let pipeline = AudioTapFixture.idlePipeline()
        let taken = TapCollector()
        let owner = NSObject()
        pipeline.addAudioTap(owner) { taken.take($0) }
        defer { pipeline.removeAudioTap(owner) }

        try AudioTapFixture.push(30, channels: Self.channels, into: pipeline)

        #expect(taken.count == 30)
        let cache = pipeline.queue.sync { pipeline.stereoFormatCache }
        #expect(cache != nil, "no mix was built for a registered tap")
        // …and the ONE description is reused across all thirty: a cache rebuilt
        // per packet is 30 `CMAudioFormatDescriptionCreate` calls on the
        // capture queue, which is what keying it on the channel count bought.
        let width: Int = cache.map {
            Int(CMAudioFormatDescriptionGetStreamBasicDescription($0)?
                .pointee.mChannelsPerFrame ?? 0)
        } ?? 0
        #expect(width == 2)
    }

    // MARK: - the timing

    /// A consumer that does the least a real one can: one atomic add, and it
    /// keeps nothing.
    ///
    /// `TapCollector` is the wrong sink for a benchmark and measurably so — it
    /// retains every buffer, so the rows below would differ by an array that
    /// grows at a different rate per row rather than by the tap. What a real
    /// consumer does with the packet is hop to its own queue, which belongs to
    /// that consumer's budget and not to the capture queue's.
    private final class TapCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = 0
        func count() { lock.withLock { stored += 1 } }
        var total: Int { lock.withLock { stored } }
    }

    @Test(.enabled(if: AudioTapCostTests.timed))
    func whatOnePacketCostsTheCaptureQueue() throws {
        // A standing-by pipeline with no writer and no pre-roll ring, so
        // `recordAudio` returns immediately and the difference between the rows
        // below is the tap and nothing else.
        for consumers in [0, 1, 2] {
            let pipeline = AudioTapFixture.idlePipeline()
            let owners = (0..<consumers).map { _ in NSObject() }
            let taken = TapCounter()
            for owner in owners {
                pipeline.addAudioTap(owner) { _ in taken.count() }
            }
            defer { for owner in owners { pipeline.removeAudioTap(owner) } }
            Self.time("audio path, \(consumers) listening",
                      pipeline: pipeline, channels: Self.channels)
        }
        // …and the case the cart is in while a stream is going: the speakers on
        // AND a transport listening, which is the pair the shared mix exists
        // for. It has to sit beside "1 listening" rather than above it.
        let pipeline = AudioTapFixture.idlePipeline()
        let owner = NSObject()
        let taken = TapCounter()
        pipeline.addAudioTap(owner) { _ in taken.count() }
        pipeline.onMonitorAudio = { _ in }
        pipeline.setAudioMonitorEnabled(true)
        defer { pipeline.removeAudioTap(owner) }
        Self.time("audio path, speakers + 1 listening",
                  pipeline: pipeline, channels: Self.channels)
    }

    /// Push a run of packets and time the QUEUE, not the pusher.
    ///
    /// The packets are built up front and the `sync` at the end is ordered
    /// behind every `async` before it, so what is being divided is the serial
    /// queue's own occupancy: the levels, the detector, the (absent) record and
    /// the tap.
    ///
    /// Several passes, and the MINIMUM is the one to compare across builds —
    /// the pass that got a whole core to itself. One pass was not enough to
    /// separate the rows: measured, a single 400-packet run put "two
    /// transports" BELOW "one", which is a machine reporting itself.
    private static func time(_ label: String, packets count: Int = 400,
                             passes: Int = 9,
                             pipeline: CapturePipeline, channels: Int) {
        var cache: CMAudioFormatDescription?
        var packets: [CMSampleBuffer] = []
        for index in 0..<count {
            guard let packet = TestMedia.audioBuffer(
                seconds: Double(index) * 0.04, channels: channels,
                signature: true, cache: &cache) else { continue }
            packets.append(packet)
        }
        for packet in packets.prefix(40) { pipeline.handleAudio(packet) }
        pipeline.queue.sync {}

        var samples: [Double] = []
        for _ in 0..<passes {
            let start = DispatchTime.now().uptimeNanoseconds
            for packet in packets { pipeline.handleAudio(packet) }
            pipeline.queue.sync {}
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start)
            samples.append(elapsed / 1000 / Double(packets.count))
        }
        samples.sort()
        print(String(format:
            "AUDIOTAPBENCH %@: min %.3f  median %.3f  max %.3f µs/packet",
            label, samples[0], samples[passes / 2], samples[passes - 1]))
    }
}
