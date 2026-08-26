import CaptureCore
import CoreMedia
import Foundation
import Testing

@testable import TakeShotKit

/// Access units that reached a sink, behind a lock: they arrive on the
/// encoder's queue and the test reads them from elsewhere, which is a data race
/// on a plain `var` and aborts the suite under TSan.
final class AACCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [LiveAudioEncoder.AccessUnit] = []
    private var storedQueues: [String] = []

    func take(_ unit: LiveAudioEncoder.AccessUnit) {
        let label = String(cString: __dispatch_queue_get_label(nil))
        lock.withLock {
            stored.append(unit)
            storedQueues.append(label)
        }
    }

    var all: [LiveAudioEncoder.AccessUnit] { lock.withLock { stored } }
    var count: Int { lock.withLock { stored.count } }
    /// The label of the queue each delivery ran on. What proves the encode is
    /// not on the capture queue the tap hands over from.
    var queues: [String] { lock.withLock { storedQueues } }
}

enum LiveAudioFixtures {
    /// 40 ms of a tone, which is the packet size the audio path delivers.
    ///
    /// A TONE and not silence: an encoder handed digital black is entitled to
    /// produce very little, and a suite that only ever fed it silence would be
    /// checking that AudioToolbox can compress nothing.
    static func packet(index: Int, channels: Int = 2,
                       cache: inout CMAudioFormatDescription?)
        -> CMSampleBuffer? {
        let frames = 1920
        var samples = [Int16](repeating: 0, count: frames * channels)
        for frame in 0..<frames {
            let phase = Double(index * frames + frame) * 2 * .pi * 440 / 48_000
            let value = Int16(20_000 * sin(phase))
            for channel in 0..<channels {
                samples[frame * channels + channel] =
                    channel == 0 ? value : -value
            }
        }
        return samples.withUnsafeBytes { raw in
            PCMAudio.makeSampleBuffer(
                bytes: raw.baseAddress!, sampleFrames: frames,
                channelCount: channels, ptsSeconds: Double(index) * 0.04,
                formatCache: &cache)
        }
    }

    /// Push `count` packets and wait for the encoder to have produced at least
    /// `expecting` units, or give up. The encode is asynchronous, so a test
    /// that read the collector straight after the last `offer` would be racing
    /// the queue.
    static func drive(_ encoder: LiveAudioEncoder, packets count: Int,
                      channels: Int = 2, into taken: AACCollector,
                      expecting: Int, timeout: TimeInterval = 10) async {
        var cache: CMAudioFormatDescription?
        for index in 0..<count {
            guard let packet = packet(index: index, channels: channels,
                                      cache: &cache) else { continue }
            encoder.offer(packet)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while taken.count < expecting, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Come back once the encoder has stopped producing.
    ///
    /// `drive` returns as soon as ENOUGH units have arrived, which is the right
    /// wait for "did anything come out" and the wrong one for a test that then
    /// changes the input: the queue is still draining, and the units that land
    /// afterwards belong to the old state. Polling for the count to hold still
    /// is what separates the two runs.
    static func settle(_ taken: AACCollector) async {
        var last = -1
        let deadline = Date().addingTimeInterval(5)
        while last != taken.count, Date() < deadline {
            last = taken.count
            try? await Task.sleep(for: .milliseconds(80))
        }
    }
}

/// The arithmetic the whole clock rests on, checked on every machine including
/// one with no AAC encoder in it.
@Suite struct LiveAudioEncoderConstantTests {
    /// **1920 ticks per access unit, exactly.** 1024 samples at 48 kHz on a
    /// 90 kHz clock is a whole number, which is what lets the stamps be an
    /// integer series with no rounding anywhere in it — and the reason to pin
    /// it rather than trust it is that a rate or a unit size that made it
    /// fractional would put a drift into the stream that nothing else here
    /// would notice.
    @Test func oneAccessUnitIsExactlyNineteenTwentyTicks() {
        #expect(LiveAudioEncoder.samplesPerAccessUnit == 1024)
        #expect(LiveAudioEncoder.sampleRate == 48_000)
        #expect(MPEGTSMuxer.clockHz == 90_000)
        #expect(LiveAudioEncoder.ticksPerAccessUnit == 1920)
        // …and it really is a whole division rather than a rounded one
        #expect(1024 * 90_000 % 48_000 == 0)
    }

    /// The bitrate is a fraction of the picture's, so sound is never the reason
    /// a link cannot carry the frame.
    @Test func theSoundIsASmallShareOfTheLink() {
        #expect(LiveAudioEncoder.defaultBitsPerSecond == 128_000)
        var srt = SRTSettings()
        srt.enabled = true
        let share = Double(LiveAudioEncoder.defaultBitsPerSecond)
            / Double(srt.bitsPerSecondEffective)
        #expect(share < 0.05, "sound is \(share) of the default link budget")
    }

    /// The resync window is far above any jitter this path sees (packets are
    /// 40 ms) and far below the gap a source going away leaves.
    @Test func theResyncWindowSitsBetweenJitterAndAGap() {
        #expect(LiveAudioEncoder.resyncTolerance > 0.04 * 4)
        #expect(LiveAudioEncoder.resyncTolerance < 1)
    }
}

/// **An idle set encodes nothing**, the sound's version of the property the
/// whole shared-encoder design is arranged around.
@Suite(.enabled(if: AACConverter.isSupported,
                "no AAC encoder on this machine"))
struct LiveAudioEncoderIdleTests {
    @Test func nothingIsEncodedWhileNothingIsListening() async throws {
        let encoder = LiveAudioEncoder()
        defer { encoder.stop() }
        let taken = AACCollector()
        await LiveAudioFixtures.drive(encoder, packets: 8, into: taken,
                                      expecting: 0)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!encoder.hasSinks)
        #expect(taken.count == 0)
        #expect(!encoder.hasConverter, "a codec was built for nobody")
    }

    /// And the moment something IS listening, the packets after it reach it.
    @Test func theFirstPacketsAfterASinkArrivesReachIt() async throws {
        let encoder = LiveAudioEncoder()
        defer { encoder.stop() }
        let taken = AACCollector()
        encoder.addSink(taken) { taken.take($0) }
        await LiveAudioFixtures.drive(encoder, packets: 10, into: taken,
                                      expecting: 8)
        #expect(taken.count >= 8, "\(taken.count) access units out of 10 packets")
        #expect(encoder.hasConverter)
    }
}

/// A real AAC encode, driven end to end.
@Suite(.enabled(if: AACConverter.isSupported,
                "no AAC encoder on this machine"))
struct LiveAudioEncoderTests {
    /// **The stamps are an exact series.** Each access unit is 1920 ticks after
    /// the one before it, forever — which is what makes the sound's clock a
    /// sample count rather than a scheduling record.
    @Test func theStampsAdvanceByExactlyOneUnitEachTime() async throws {
        let encoder = LiveAudioEncoder()
        defer { encoder.stop() }
        let taken = AACCollector()
        encoder.addSink(taken) { taken.take($0) }
        await LiveAudioFixtures.drive(encoder, packets: 20, into: taken,
                                      expecting: 16)

        let units: [LiveAudioEncoder.AccessUnit] = taken.all
        #expect(units.count >= 16, "only \(units.count) access units")
        for index in 1..<units.count {
            let step: Int64 = units[index].ticks - units[index - 1].ticks
            #expect(step == LiveAudioEncoder.ticksPerAccessUnit,
                    "unit \(index) is \(step) ticks after the one before it")
        }
    }

    /// Every unit carries what the muxer needs to frame it, taken from the
    /// encoder rather than from a setting — so an ADTS header cannot describe a
    /// stream the converter is not producing.
    @Test func everyUnitStatesItsOwnRateAndWidth() async throws {
        let encoder = LiveAudioEncoder()
        defer { encoder.stop() }
        let taken = AACCollector()
        encoder.addSink(taken) { taken.take($0) }
        await LiveAudioFixtures.drive(encoder, packets: 12, into: taken,
                                      expecting: 8)

        let units: [LiveAudioEncoder.AccessUnit] = taken.all
        #expect(!units.isEmpty)
        for unit in units {
            #expect(unit.sampleRate == 48_000)
            #expect(unit.channels == 2)
            #expect(!unit.payload.isEmpty, "an empty access unit went out")
            // A 128 kbit/s stereo unit is a few hundred bytes; anything near
            // the format's own 8191-byte ceiling would mean the length field
            // was about to overflow.
            #expect(unit.payload.count < 8_191 - MPEGTSMuxer.adtsHeaderBytes)
        }
    }

    /// **A MONO tap travels.** The channel mask can leave one channel enabled,
    /// and the encoder states one rather than inventing a second.
    @Test func aSingleChannelFeedEncodesAsMono() async throws {
        let encoder = LiveAudioEncoder()
        defer { encoder.stop() }
        let taken = AACCollector()
        encoder.addSink(taken) { taken.take($0) }
        await LiveAudioFixtures.drive(encoder, packets: 12, channels: 1,
                                      into: taken, expecting: 8)

        let units: [LiveAudioEncoder.AccessUnit] = taken.all
        #expect(!units.isEmpty)
        #expect(units.allSatisfy { $0.channels == 1 })
    }

    /// **The encode is never on the caller's queue.** The tap hands packets
    /// over on the capture queue, and an AAC encode there is the per-frame path
    /// waiting behind a codec.
    @Test func theEncodeNeverRunsOnTheCallersQueue() async throws {
        let encoder = LiveAudioEncoder()
        defer { encoder.stop() }
        let taken = AACCollector()
        encoder.addSink(taken) { taken.take($0) }
        await LiveAudioFixtures.drive(encoder, packets: 12, into: taken,
                                      expecting: 8)

        let queues: [String] = taken.queues
        #expect(!queues.isEmpty)
        #expect(Set(queues) == [LiveAudioEncoder.queueLabel],
                "units were delivered from \(Set(queues))")
    }

    /// A source that changes its own channel count gets a new converter and a
    /// fresh clock rather than a mis-interleave: an AAC stream states its
    /// channel configuration in every header, and feeding two counts through
    /// one converter is the failure `TakeWriter.conformed` exists to stop one
    /// path along.
    @Test func aChannelCountChangeRestartsTheStream() async throws {
        let encoder = LiveAudioEncoder()
        defer { encoder.stop() }
        let taken = AACCollector()
        encoder.addSink(taken) { taken.take($0) }
        await LiveAudioFixtures.drive(encoder, packets: 10, into: taken,
                                      expecting: 6)
        await LiveAudioFixtures.settle(taken)
        let stereo: Int = taken.count
        #expect(stereo >= 6)
        await LiveAudioFixtures.drive(encoder, packets: 10, channels: 1,
                                      into: taken, expecting: stereo + 6)

        let units: [LiveAudioEncoder.AccessUnit] = taken.all
        #expect(units.prefix(stereo).allSatisfy { $0.channels == 2 })
        #expect(units.dropFirst(stereo).allSatisfy { $0.channels == 1 },
                "a packet of the old width came out after the change")
    }

    /// A stopped encoder is inert, and its sinks are gone with it.
    @Test func stoppingDropsTheCodecAndTheSinks() async throws {
        let encoder = LiveAudioEncoder()
        let taken = AACCollector()
        encoder.addSink(taken) { taken.take($0) }
        await LiveAudioFixtures.drive(encoder, packets: 10, into: taken,
                                      expecting: 6)
        await LiveAudioFixtures.settle(taken)
        let before: Int = taken.count
        encoder.stop()

        // A short budget: this one waits for something that must NOT happen, so
        // the timeout is the whole runtime rather than a safety margin.
        await LiveAudioFixtures.drive(encoder, packets: 10, into: taken,
                                      expecting: before + 1, timeout: 0.5)
        #expect(taken.count == before,
                "\(taken.count - before) units arrived after stop()")
        #expect(!encoder.hasSinks)
        #expect(!encoder.hasConverter)
    }
}
