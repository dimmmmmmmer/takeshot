import AVFoundation
import CoreMedia
import Foundation
import Testing

@testable import TakeShotKit

/// The conversion layer between a device's native stream and the pipeline's
/// wire format. The fake device is stepped by hand, so every assertion is
/// about exact frame counts — no timers, no real hardware.
struct ExternalAudioSourceTests {
    /// 44.1 kHz in, 48 kHz out, and the DURATION survives: two seconds of
    /// input still cover two seconds of take within one video frame — the
    /// budget a resampler is allowed to hold back as filter state.
    @Test func a441kHzDeviceIsResampledTo48kPreservingDuration() throws {
        let device = FakeAudioCaptureDevice(channelCount: 2,
                                            sampleRate: 44_100,
                                            amplitude: 6000,
                                            automatic: false)
        let source = ExternalAudioSource(device: device)
        let packets = PacketCollector()
        source.onPacket = { packets.append($0) }
        try source.start()
        defer { source.stop() }

        for _ in 0..<50 { device.pushOnce() } // 50 × 40 ms = 2.0 s of input

        let all = packets.all
        let first = try #require(all.first, "no packets came out at all")
        let asbd = try #require(CMSampleBufferGetFormatDescription(first)
            .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee })
        #expect(asbd.mSampleRate == 48_000)
        #expect(asbd.mChannelsPerFrame == 2)
        #expect(asbd.mBitsPerChannel == 16)

        let frames = all.reduce(0) { $0 + CMSampleBufferGetNumSamples($1) }
        let seconds = Double(frames) / 48_000
        #expect(abs(seconds - 2.0) <= 0.04,
                "2.0 s in, \(seconds) s out — the conversion changed duration")

        // the tone's level survives the resampler (a middle packet: the
        // filter's warm-up ramp is allowed to shave the very first one)
        let middle = TestAudioKit.int16Samples(of: all[all.count / 2])
        let peak = middle.map { abs(Int($0)) }.max() ?? 0
        #expect(peak > 4800, "peak \(peak) after resampling a 6000 tone")

        // PTS runs contiguously: last packet's end == first packet's start
        // plus everything delivered
        let last = try #require(all.last)
        let start = CMSampleBufferGetPresentationTimeStamp(first)
        let end = CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(last),
                            CMSampleBufferGetDuration(last))
        #expect(abs(CMTimeSubtract(end, start).seconds - seconds) < 0.001,
                "the packet timeline has holes in it")
    }

    /// A device already speaking the wire format passes through sample-exact,
    /// with its own host-clock timestamps preserved on the first packet.
    @Test func a48kInt16DevicePassesThroughUntouched() throws {
        let device = FakeAudioCaptureDevice(channelCount: 4,
                                            sampleRate: 48_000,
                                            amplitude: 1234,
                                            automatic: false)
        let source = ExternalAudioSource(device: device)
        let packets = PacketCollector()
        source.onPacket = { packets.append($0) }
        try source.start()
        defer { source.stop() }

        let before = CMClockGetTime(CMClockGetHostTimeClock())
        for _ in 0..<5 { device.pushOnce() }
        let after = CMClockGetTime(CMClockGetHostTimeClock())

        let all = packets.all
        #expect(all.count == 5)
        let first = try #require(all.first)
        #expect(CMSampleBufferGetNumSamples(first) == 1920)
        let samples = TestAudioKit.int16Samples(of: first)
        #expect(samples.count == 1920 * 4)
        #expect(samples.allSatisfy { $0 == 1234 },
                "passthrough changed the samples")
        // the packet still carries the device's host-clock time
        let pts = CMSampleBufferGetPresentationTimeStamp(first)
        #expect(pts >= before && pts <= after,
                "the passthrough packet lost its host timestamp")
    }

    @Test func theDeviceGoneCallbackPropagates() throws {
        let device = FakeAudioCaptureDevice(automatic: false)
        let source = ExternalAudioSource(device: device)
        let gone = HitCounter()
        source.onDeviceGone = { gone.bump() }
        try source.start()

        device.vanish()

        #expect(gone.value == 1)
        #expect(!device.started)
    }
}
