import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import CaptureCore

/// A tap's packets, behind a lock: they arrive on the pipeline queue and the
/// test reads them from a concurrency worker, which is a data race on a plain
/// `var` and aborts the suite under TSan.
///
/// The BUFFERS are kept, not a count — half of what this suite has to answer is
/// about which channels reached the wire, and the other half is about the two
/// consumers getting the same object rather than two equal ones.
final class TapCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [CMSampleBuffer] = []

    func take(_ buffer: CMSampleBuffer) {
        lock.withLock { stored.append(buffer) }
    }

    var all: [CMSampleBuffer] { lock.withLock { stored } }
    var count: Int { lock.withLock { stored.count } }

    /// The channel count of the last packet that arrived; 0 when none has.
    var lastChannelCount: Int {
        lock.withLock { stored.last.map { PCMAudio.channelCount(of: $0) } ?? 0 }
    }

    /// The samples of the last packet, interleaved.
    var lastSamples: [Int16] {
        lock.withLock { stored.last.flatMap { PCMAudio.interleavedSamples(of: $0) } ?? [] }
    }
}

enum AudioTapFixture {
    /// A standing-by pipeline: format known, nothing recording, no pre-roll —
    /// so `recordAudio` does nothing at all and what a packet costs is the
    /// levels, the detector and the tap.
    static func idlePipeline(preRollSeconds: Double = 0) -> CapturePipeline {
        var settings = CaptureSettings()
        settings.capture.preRollSeconds = preRollSeconds
        settings.capture.detectionMode = .vanc
        let pipeline = CapturePipeline(config: .init(
            settings: settings, slate: SlateMetadata(scene: "1"), takeNumber: 1))
        pipeline.handleFormat(CaptureFormat(width: 320, height: 180,
                                            frameRate: 25, timecodeFPS: 25,
                                            name: "test"))
        return pipeline
    }

    /// One packet with every channel carrying its own identifiable value.
    static func packet(seconds: Double, channels: Int,
                       cache: inout CMAudioFormatDescription?) throws
        -> CMSampleBuffer {
        try #require(TestMedia.audioBuffer(seconds: seconds, channels: channels,
                                           signature: true, cache: &cache))
    }

    /// Push `count` packets and come back when the pipeline queue has run them
    /// all. A barrier on the pipeline's own queue rather than a poll: every
    /// consequence of `handleAudio` happens on it, so a `sync` after the last
    /// `async` is ordered behind all of them.
    static func push(_ count: Int, channels: Int, into pipeline: CapturePipeline,
                     from first: Int = 1) throws {
        var cache: CMAudioFormatDescription?
        for index in first..<(first + count) {
            let packet = try packet(seconds: Double(index) * 0.04,
                                    channels: channels, cache: &cache)
            pipeline.handleAudio(packet)
        }
        pipeline.queue.sync {}
    }
}

/// **The tap is independent of the monitor**, which is the whole reason it
/// exists rather than being a second callback on `onMonitorAudio`.
///
/// Everything in this suite runs with `monitorEnabled` at its default, which is
/// FALSE — a pipeline nobody has switched the speakers on for. That is the
/// condition an SRT feed lives in on a cart where the operator is on
/// headphones, and it is the condition under which the old design delivered
/// nothing at all.
struct AudioTapIndependenceTests {
    @Test func theTapDeliversWithTheMonitorOff() throws {
        let pipeline = AudioTapFixture.idlePipeline()
        let taken = TapCollector()
        let owner = NSObject()
        pipeline.addAudioTap(owner) { taken.take($0) }
        defer { pipeline.removeAudioTap(owner) }

        try AudioTapFixture.push(4, channels: 8, into: pipeline)

        #expect(taken.count == 4,
                "\(taken.count) packets reached the wire with the speakers off")
        #expect(taken.lastChannelCount == 2)
    }

    /// …and switching the speakers ON does not make the tap deliver twice.
    ///
    /// The negative half of the same fact, and the one that would go unnoticed:
    /// a design where the tap were fed from inside the monitor's own branch
    /// would pass the test above by accident (a second call site) and then send
    /// every packet twice to a receiver the moment the operator turned the cart
    /// up.
    @Test func theMonitorGoingOnDoesNotDoubleTheTap() async throws {
        let pipeline = AudioTapFixture.idlePipeline()
        let taken = TapCollector()
        let heard = TapCollector()
        let owner = NSObject()
        pipeline.addAudioTap(owner) { taken.take($0) }
        pipeline.onMonitorAudio = { heard.take($0) }
        pipeline.setAudioMonitorEnabled(true)
        defer { pipeline.removeAudioTap(owner) }

        try AudioTapFixture.push(6, channels: 8, into: pipeline)

        #expect(taken.count == 6, "the tap got \(taken.count) of 6 packets")
        #expect(heard.count == 6, "the speakers got \(heard.count) of 6 packets")
    }

    /// **One mix, not two.** The buffer the speakers get and the buffer the wire
    /// gets are the SAME OBJECT, which is the only way to say "the work is not
    /// done twice" that cannot be satisfied by two equal answers.
    ///
    /// Identity rather than equality on purpose: two `selectChannels` calls on
    /// one packet produce buffers with identical bytes, so a byte comparison
    /// would pass on the design this test exists to rule out.
    @Test func theSpeakersAndTheWireShareOneMix() throws {
        let pipeline = AudioTapFixture.idlePipeline()
        let taken = TapCollector()
        let heard = TapCollector()
        let owner = NSObject()
        pipeline.addAudioTap(owner) { taken.take($0) }
        pipeline.onMonitorAudio = { heard.take($0) }
        pipeline.setAudioMonitorEnabled(true)
        defer { pipeline.removeAudioTap(owner) }

        try AudioTapFixture.push(3, channels: 8, into: pipeline)

        let wire = taken.all
        let speakers = heard.all
        #expect(wire.count == 3)
        #expect(speakers.count == 3)
        for (index, pair) in zip(wire, speakers).enumerated() {
            #expect(pair.0 === pair.1,
                    "packet \(index) was mixed twice: \(pair.0) vs \(pair.1)")
        }
    }

    /// A removed tap stops costing anything, and the pipeline says so.
    ///
    /// `hasAudioTaps` is what the per-packet guard reads, so a tap that was
    /// removed from the dictionary but left the guard true would keep building
    /// a mix for nobody — visible here and nowhere else.
    @Test func aRemovedTapStopsDelivering() throws {
        let pipeline = AudioTapFixture.idlePipeline()
        let taken = TapCollector()
        let owner = NSObject()
        pipeline.addAudioTap(owner) { taken.take($0) }
        #expect(pipeline.hasAudioTaps)

        try AudioTapFixture.push(2, channels: 8, into: pipeline)
        let delivered = taken.count
        pipeline.removeAudioTap(owner)
        #expect(!pipeline.hasAudioTaps)

        try AudioTapFixture.push(5, channels: 8, into: pipeline, from: 20)
        #expect(taken.count == delivered,
                "\(taken.count - delivered) packets arrived after removal")
    }

    /// Two transports on one tap each get the packet, and it is still one mix.
    ///
    /// The registry's reason for being a registry: a single slot would have made
    /// the second output to be switched on silence the first, which is a bug
    /// nobody would find until two feeds were running at once on a shoot.
    @Test func twoTransportsBothGetTheSameMix() throws {
        let pipeline = AudioTapFixture.idlePipeline()
        let first = TapCollector()
        let second = TapCollector()
        let ownerA = NSObject()
        let ownerB = NSObject()
        pipeline.addAudioTap(ownerA) { first.take($0) }
        pipeline.addAudioTap(ownerB) { second.take($0) }
        defer {
            pipeline.removeAudioTap(ownerA)
            pipeline.removeAudioTap(ownerB)
        }

        try AudioTapFixture.push(3, channels: 8, into: pipeline)

        #expect(first.count == 3)
        #expect(second.count == 3)
        for (index, pair) in zip(first.all, second.all).enumerated() {
            #expect(pair.0 === pair.1, "packet \(index) was mixed per consumer")
        }
    }

    /// The same object registering twice is one tap, not two — the contract
    /// `LiveVideoEncoder.addSink` already has, and the reason removal needs
    /// nothing but the object.
    @Test func registeringTwiceIsStillOneTap() throws {
        let pipeline = AudioTapFixture.idlePipeline()
        let taken = TapCollector()
        let owner = NSObject()
        pipeline.addAudioTap(owner) { taken.take($0) }
        pipeline.addAudioTap(owner) { taken.take($0) }
        defer { pipeline.removeAudioTap(owner) }

        try AudioTapFixture.push(4, channels: 8, into: pipeline)

        #expect(taken.count == 4, "\(taken.count) deliveries for 4 packets")
    }
}

/// **Which channels go out**, which is a decision rather than a detail.
///
/// The rule: the first two ENABLED by the mask in force — the operator's own
/// when they have given one, the standby measurement's when they have not, and
/// 1-2 when neither has an answer. What that buys is that a director hears what
/// the FILE is getting, folded to two, and what it rules out is a fixed 1-2 on
/// a rig where the live pair is 5-6.
struct AudioTapChannelTests {
    /// The operator's mask decides, and it is not the first two channels of the
    /// SOURCE that go out.
    @Test func theTapTakesTheFirstTwoChannelsTheOperatorEnabled() throws {
        var settings = CaptureSettings()
        settings.capture.detectionMode = .vanc
        // channels 5, 6 and 8 (bits 4, 5 and 7) — a plausible boom-plus-radios
        // patch, and deliberately not adjacent to 1-2
        settings.audio.audioChannelMask = (1 << 4) | (1 << 5) | (1 << 7)
        let pipeline = CapturePipeline(config: .init(
            settings: settings, slate: SlateMetadata(scene: "1"), takeNumber: 1))
        let taken = TapCollector()
        let owner = NSObject()
        pipeline.addAudioTap(owner) { taken.take($0) }
        defer { pipeline.removeAudioTap(owner) }

        try AudioTapFixture.push(1, channels: 8, into: pipeline)

        #expect(taken.lastChannelCount == 2)
        let samples: [Int16] = taken.lastSamples
        // Required rather than expected: everything below indexes into it, and
        // a test that crashes on an empty array takes the rest of the suite
        // with it instead of reporting.
        try #require(samples.count == 1920 * 2)
        // frame 0 of the packet at 0.04 s: channel 4 in the left slot and
        // channel 5 in the right, which is 5 and 6 as an operator counts them
        #expect(samples[0] == TestMedia.audioSignature(frame: 0, channel: 4,
                                                       seconds: 0.04),
                "the left slot is not channel 5")
        #expect(samples[1] == TestMedia.audioSignature(frame: 0, channel: 5,
                                                       seconds: 0.04),
                "the right slot is not channel 6")
        // …and channel 8 is dropped rather than folded in: the far end is a
        // monitor, and the fold is to TWO
        #expect(samples[2] == TestMedia.audioSignature(frame: 1, channel: 4,
                                                       seconds: 0.04),
                "a third channel got into a stereo feed")
    }

    /// With no mask anywhere, 1-2. The case a fresh install is in, and the one
    /// every stereo embed stays in.
    @Test func withNoMaskAtAllItIsTheFirstTwo() throws {
        let pipeline = AudioTapFixture.idlePipeline()
        let taken = TapCollector()
        let owner = NSObject()
        pipeline.addAudioTap(owner) { taken.take($0) }
        defer { pipeline.removeAudioTap(owner) }

        try AudioTapFixture.push(1, channels: 8, into: pipeline)

        let samples: [Int16] = taken.lastSamples
        #expect(taken.lastChannelCount == 2)
        try #require(samples.count == 1920 * 2)
        #expect(samples[0] == TestMedia.audioSignature(frame: 0, channel: 0,
                                                       seconds: 0.04))
        #expect(samples[1] == TestMedia.audioSignature(frame: 0, channel: 1,
                                                       seconds: 0.04))
    }

    /// One enabled channel goes out MONO rather than doubled.
    ///
    /// Both legs off the tap state a channel count — ADTS carries a channel
    /// configuration and NDI takes one as an argument — so mono travels
    /// correctly, and copying a channel into a second slot would be the app
    /// inventing sound that was never recorded.
    @Test func oneEnabledChannelIsMonoAndNotDoubled() throws {
        var settings = CaptureSettings()
        settings.capture.detectionMode = .vanc
        settings.audio.audioChannelMask = 1 << 2 // channel 3 alone
        let pipeline = CapturePipeline(config: .init(
            settings: settings, slate: SlateMetadata(scene: "1"), takeNumber: 1))
        let taken = TapCollector()
        let owner = NSObject()
        pipeline.addAudioTap(owner) { taken.take($0) }
        defer { pipeline.removeAudioTap(owner) }

        try AudioTapFixture.push(1, channels: 8, into: pipeline)

        let width: Int = taken.lastChannelCount
        #expect(width == 1, "a single enabled channel came out \(width) wide")
        try #require(!taken.lastSamples.isEmpty)
        #expect(taken.lastSamples[0]
            == TestMedia.audioSignature(frame: 0, channel: 2, seconds: 0.04))
    }

    /// The measurement fills the nil, exactly as it does for the file.
    ///
    /// This is what makes the rule "the channels in force" rather than "the
    /// operator's mask": on a sixteen-channel embed where only 5-6 carry
    /// anything, `AudioChannelDetector` is the only thing that knows, and a
    /// director handed 1-2 gets two dead channels with nothing saying so.
    @Test func theStandbyMeasurementFillsTheNil() throws {
        let pipeline = AudioTapFixture.idlePipeline()
        let taken = TapCollector()
        let owner = NSObject()
        pipeline.addAudioTap(owner) { taken.take($0) }
        defer { pipeline.removeAudioTap(owner) }

        // A source where only channels 5 and 6 carry a stream. The detector
        // needs a full second of it before it answers at all.
        var cache: CMAudioFormatDescription?
        let channels = 8
        let frames = 1920
        var samples = [Int16](repeating: 0, count: frames * channels)
        for frame in 0..<frames {
            samples[frame * channels + 4] = 1000
            samples[frame * channels + 5] = -1000
        }
        for index in 1...30 {
            let packet: CMSampleBuffer? = samples.withUnsafeBytes { raw in
                PCMAudio.makeSampleBuffer(
                    bytes: raw.baseAddress!, sampleFrames: frames,
                    channelCount: channels, ptsSeconds: Double(index) * 0.04,
                    formatCache: &cache)
            }
            pipeline.handleAudio(try #require(packet))
        }
        pipeline.queue.sync {}

        #expect(pipeline.queue.sync { pipeline.detectedAudioMask }
            == (1 << 4) | (1 << 5), "the measurement did not settle")
        #expect(taken.lastChannelCount == 2)
        let last: [Int16] = taken.lastSamples
        try #require(last.count >= 2)
        #expect(last[0] == 1000 && last[1] == -1000,
                "the wire got \(last[0])/\(last[1]) — not the channels that carry")
    }

    /// **The wire's channels are a PREFIX of the file's, for every mask.**
    ///
    /// The one property that says the two rules cannot diverge: both read
    /// `activeAudioChannelMask`, so whatever the operator, the measurement or a
    /// take's latch puts in force, what a director hears is the first two of
    /// what is being written and never a third set of channels. The alternative
    /// is the operator on the cart and the director on a laptop hearing
    /// different pairs, which is how "can you hear the boom?" gets two answers.
    @Test func theWireIsAlwaysAPrefixOfWhatTheFileGets() {
        for mask: Int in [0b11, 0b1100, 0b1011_0000, 0b100, 0xFFFF] {
            var settings = CaptureSettings()
            settings.audio.audioChannelMask = mask
            let pipeline = CapturePipeline(config: .init(
                settings: settings, slate: SlateMetadata(scene: "1"),
                takeNumber: 1))
            let toFile: [Int] = CapturePipeline.channels(in: mask)
            let toWire: [Int] = pipeline.queue.sync {
                pipeline.stereoChannelIndices
            }
            let bits: String = String(mask, radix: 2)
            #expect(toWire == Array(toFile.prefix(2)),
                    "mask \(bits): file \(toFile), wire \(toWire)")
            #expect(toWire.count <= 2)
        }
    }
}
