import AVFoundation
import CaptureCore
import CoreMedia
import Foundation
import Testing

@testable import TakeShotKit

/// The USB input's sample-buffer → PCM conversion.
///
/// The device layer around it opens hardware and no suite may go near it, but the
/// conversion itself is arithmetic on a buffer the test can build. It is worth
/// holding because the multichannel rule under it was a silent nil: past two
/// channels `AVAudioFormat(streamDescription:)` refuses without a channel layout,
/// so every USB interface with more than a stereo pair delivered nothing at all
/// and the meters simply stayed dark.
@Suite struct ModelAudioPCMConversionTests {
    /// A packet in the shape a USB interface delivers: interleaved signed 16-bit
    /// PCM at 48 kHz, `channels` wide, with channel `n` filled with `n + 1` so a
    /// conversion that reordered or dropped one is visible.
    private static func packet(channels: Int, frames: Int = 512)
        -> CMSampleBuffer {
        var samples = [Int16](repeating: 0, count: frames * channels)
        for frame in 0..<frames {
            for channel in 0..<channels {
                samples[frame * channels + channel] = Int16(channel + 1)
            }
        }
        var cache: CMAudioFormatDescription?
        let buffer = samples.withUnsafeBytes { raw -> CMSampleBuffer? in
            guard let base = raw.baseAddress else { return nil }
            return PCMAudio.makeSampleBuffer(
                bytes: base, sampleFrames: frames, channelCount: channels,
                ptsSeconds: 0, formatCache: &cache)
        }
        guard let buffer else {
            fatalError("could not build a \(channels)-channel packet")
        }
        return buffer
    }

    /// A stereo interface: the plain initializer is enough, and the samples come
    /// through unchanged.
    @Test func aStereoPacketConvertsWithItsSamplesIntact() throws {
        let pcm = try #require(SystemAudioCaptureDevice.pcmBuffer(
            from: Self.packet(channels: 2)))
        #expect(pcm.format.channelCount == 2)
        #expect(pcm.format.sampleRate == 48_000)
        #expect(pcm.frameLength == 512)

        let data = try #require(pcm.int16ChannelData)
        // interleaved: one buffer, samples side by side
        #expect(data[0][0] == 1)
        #expect(data[0][1] == 2)
    }

    /// The case that used to return nothing: more than two channels. A 32-channel
    /// interface is normal on a feature, and an input that silently delivers no
    /// packets reads as a dead cable.
    @Test(arguments: [4, 8, 16, 32])
    func aMultichannelPacketConverts(channels: Int) throws {
        let pcm = try #require(
            SystemAudioCaptureDevice.pcmBuffer(from: Self.packet(channels: channels)),
            "a \(channels)-channel packet converted to nothing")
        #expect(pcm.format.channelCount == AVAudioChannelCount(channels))
        #expect(pcm.frameLength == 512)

        let data = try #require(pcm.int16ChannelData)
        // every channel is present and in order, not folded down to a pair
        for channel in 0..<channels {
            #expect(data[0][channel] == Int16(channel + 1),
                    "channel \(channel) arrived as \(data[0][channel])")
        }
    }

    /// The layout a multichannel format is given is DISCRETE and in order: a
    /// device's interleaved PCM is positional — channel 3 is whatever is plugged
    /// into input 3 — so claiming a surround layout would label the operator's
    /// inputs with speaker positions nobody chose.
    @Test func aMultichannelFormatIsLaidOutDiscreteInOrder() throws {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger
                | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 16, mFramesPerPacket: 1, mBytesPerFrame: 16,
            mChannelsPerFrame: 8, mBitsPerChannel: 16, mReserved: 0)
        let format = try #require(SystemAudioCaptureDevice.format(for: &asbd))
        let layout = try #require(format.channelLayout)
        #expect(layout.layoutTag
                    == kAudioChannelLayoutTag_DiscreteInOrder | 8)
    }

    /// Two channels and fewer take the plain path with no layout at all — the
    /// initializer knows mono and stereo, and inventing a layout for them would
    /// be a second answer to a question already settled.
    @Test(arguments: [UInt32(1), UInt32(2)])
    func aStereoOrMonoFormatNeedsNoLayout(channels: UInt32) throws {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger
                | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2 * channels, mFramesPerPacket: 1,
            mBytesPerFrame: 2 * channels, mChannelsPerFrame: channels,
            mBitsPerChannel: 16, mReserved: 0)
        let format = try #require(SystemAudioCaptureDevice.format(for: &asbd))
        #expect(format.channelCount == AVAudioChannelCount(channels))
    }

    /// A packet with no samples in it converts to nothing rather than to an empty
    /// buffer the meters would read as silence. A device spinning up delivers
    /// these, and silence and "nothing yet" are different states on the panel.
    @Test func anEmptyPacketConvertsToNothing() throws {
        var cache: CMAudioFormatDescription?
        let placeholder = [Int16](repeating: 0, count: 2)
        let empty = placeholder.withUnsafeBytes { raw -> CMSampleBuffer? in
            guard let base = raw.baseAddress else { return nil }
            return PCMAudio.makeSampleBuffer(
                bytes: base, sampleFrames: 0, channelCount: 2, ptsSeconds: 0,
                formatCache: &cache)
        }
        // A zero-length packet is not always constructible; when it is, the
        // conversion has to refuse it rather than hand the meters an empty
        // buffer, which they would read as silence.
        if let empty {
            #expect(SystemAudioCaptureDevice.pcmBuffer(from: empty) == nil)
        }
    }

    /// A packet with no format description at all — the shape a torn-down session
    /// can still hand over — converts to nothing instead of trapping.
    @Test func aPacketWithNoFormatConvertsToNothing() throws {
        var timing = CMSampleTimingInfo(duration: .zero,
                                        presentationTimeStamp: .zero,
                                        decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: nil,
            sampleCount: 0, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &out)
        let formatless = try #require(out)
        #expect(SystemAudioCaptureDevice.pcmBuffer(from: formatless) == nil)
    }
}
