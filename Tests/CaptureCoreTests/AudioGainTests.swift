import AVFoundation
import CoreMedia
import Foundation
import Testing

@testable import CaptureCore

/// **Every review copy at the same level** — the gain the loudness
/// measurement is for, and the two limits on it.
@Suite(.timeLimit(.minutes(2))) struct AudioGainTests {
    // MARK: - the number

    /// **−23 LUFS, which is EBU R128's programme target**, written out rather
    /// than read off the constant: a test that compares a result against the
    /// same constant it was computed from cannot tell you the target moved.
    /// The broadcast standard and not a streaming one, because a daily is
    /// production paperwork — and a viewer can turn a knob up, while nothing
    /// undoes a clip.
    @Test func theTargetIsTheBroadcastStandard() {
        #expect(AudioGain.targetLUFS == -23)
        #expect(AudioGain.ceilingDBFS == -1)
        #expect(AudioGain.maximumBoost == 12)
    }

    /// The plain case: a take below the target comes up by exactly the
    /// difference.
    @Test func aQuietTakeComesUpToTheTarget() throws {
        let gain = try #require(AudioGain.decibels(loudness: -30, peak: 0.1))
        #expect(abs(gain - 7) < 0.01, "\(gain)")
    }

    /// …and a hot one comes down, with nothing capping the way down: turning
    /// a take down never costs anything.
    @Test func aLoudTakeComesDownHoweverFar() throws {
        let gain = try #require(AudioGain.decibels(loudness: -5, peak: 0.5))
        #expect(abs(gain - -18) < 0.01, "\(gain)")
        let extreme = try #require(AudioGain.decibels(loudness: 0, peak: 0.5))
        #expect(abs(extreme - -23) < 0.01, "\(extreme)")
    }

    /// **Up is capped.** A boost brings the noise floor with it, and past a
    /// dozen decibels the source has a problem no gain fixes.
    @Test func theBoostStopsAtTheCap() throws {
        let gain = try #require(AudioGain.decibels(loudness: -60, peak: 0.001))
        #expect(gain == AudioGain.maximumBoost, "\(gain)")
    }

    /// **And the ceiling is a promise about the OUTPUT.** A quiet programme
    /// with one loud transient in it is exactly the take a boost would clip,
    /// so the peak wins over the target.
    @Test func aLoudTransientHoldsTheGainDown() throws {
        // −40 LUFS wants +12 (capped), but the transient is at full scale
        let gain = try #require(AudioGain.decibels(loudness: -40, peak: 1))
        #expect(abs(gain - AudioGain.ceilingDBFS) < 0.01, "\(gain)")
        // …and a take already over the ceiling comes down by what that takes
        let over = try #require(AudioGain.decibels(loudness: -23, peak: 1))
        #expect(over < 0, "\(over)")
    }

    /// Nothing measured, no gain: a number computed from silence is a number
    /// nobody measured.
    @Test func silenceGetsNoGainAtAll() {
        #expect(AudioGain.decibels(loudness: nil, peak: 0) == nil)
        #expect(AudioGain.factor(loudness: nil, peak: 0.5) == nil)
        #expect(AudioGain.decibels(loudness: .nan, peak: 0.5) == nil)
    }

    @Test func theFactorIsTheDecibelsAsAMultiplier() throws {
        let factor = try #require(AudioGain.factor(loudness: -29, peak: 0.1))
        #expect(abs(factor - 2) < 0.01, "\(factor)")
    }

    // MARK: - the samples

    /// One buffer of interleaved 16-bit stereo, at a constant level.
    private func buffer(level: Int16, frames: Int = 480) throws
        -> CMSampleBuffer {
        var description: CMAudioFormatDescription?
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger
                | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        try #require(CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0,
            layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &description) == noErr)
        let samples = [Int16](repeating: level, count: frames * 2)
        let bytes = samples.count * 2
        var block: CMBlockBuffer?
        try #require(CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: bytes, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: bytes,
            flags: 0, blockBufferOut: &block) == noErr)
        let target: CMBlockBuffer = try #require(block)
        try #require(samples.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(
                with: try #require(raw.baseAddress), blockBuffer: target,
                offsetIntoDestination: 0, dataLength: bytes)
        } == noErr)
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        try #require(CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: target,
            formatDescription: description, sampleCount: frames,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &sample) == noErr)
        return try #require(sample)
    }

    private func levels(of sample: CMSampleBuffer) -> [Int16] {
        DailiesTranscode.samples(of: sample)
    }

    @Test func aGainScalesEverySample() throws {
        let scaled: CMSampleBuffer = try #require(
            AudioGain.apply(2, to: try buffer(level: 1000)))
        let out = levels(of: scaled)
        #expect(out.count == 960)
        #expect(out.allSatisfy { $0 == 2000 }, "\(Set(out).sorted())")
    }

    /// **A factor of one hands the buffer straight back**, so a run with
    /// normalisation off — or a take already on the target — costs nothing.
    @Test func noGainIsNoWorkAtAll() throws {
        let original = try buffer(level: 1000)
        let same: CMSampleBuffer = try #require(AudioGain.apply(1, to: original))
        #expect(same === original)
    }

    /// Full scale on the way out is ±32 767: −32 768 has no positive twin, and
    /// a sample that wrapped instead of clipping is a click in a review copy.
    @Test func aSampleThatWouldOverflowClipsRatherThanWraps() throws {
        let scaled: CMSampleBuffer = try #require(
            AudioGain.apply(8, to: try buffer(level: 20_000)))
        #expect(levels(of: scaled).allSatisfy { $0 == 32_767 })
        let negative: CMSampleBuffer = try #require(
            AudioGain.apply(8, to: try buffer(level: -20_000)))
        #expect(levels(of: negative).allSatisfy { $0 == -32_767 })
        #expect(AudioGain.clamp(-40_000) == -32_767)
        #expect(AudioGain.clamp(.nan) == 0)
    }

    /// The original is left alone: a decoder's block buffer may be shared with
    /// something that has not finished with it, and the failure that would
    /// produce is the kind nobody reproduces.
    @Test func theSourceBufferIsNotWrittenInto() throws {
        let original = try buffer(level: 1000)
        _ = AudioGain.apply(4, to: original)
        #expect(levels(of: original).allSatisfy { $0 == 1000 })
    }
}
