@preconcurrency import CoreMedia
import Foundation

/// Utilities for 16-bit interleaved PCM audio (shared by backends and pipeline).
public enum PCMAudio {
    /// A CMSampleBuffer from raw interleaved Int16 samples, 48 kHz.
    public static func makeSampleBuffer(bytes: UnsafeRawPointer, sampleFrames: Int,
                                        channelCount: Int, ptsSeconds: Double,
                                        formatCache: inout CMAudioFormatDescription?) -> CMSampleBuffer? {
        if formatCache == nil {
            var asbd = AudioStreamBasicDescription(
                mSampleRate: 48_000,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                mBytesPerPacket: UInt32(2 * channelCount),
                mFramesPerPacket: 1,
                mBytesPerFrame: UInt32(2 * channelCount),
                mChannelsPerFrame: UInt32(channelCount),
                mBitsPerChannel: 16,
                mReserved: 0)
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, asbd: &asbd,
                layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                extensions: nil, formatDescriptionOut: &formatCache)
        }
        guard let formatDescription = formatCache else { return nil }

        let dataLength = sampleFrames * 2 * channelCount
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: dataLength,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: dataLength, flags: 0,
            blockBufferOut: &blockBuffer) == noErr, let blockBuffer else { return nil }
        guard CMBlockBufferReplaceDataBytes(
            with: bytes, blockBuffer: blockBuffer,
            offsetIntoDestination: 0, dataLength: dataLength) == noErr else { return nil }

        var sampleBuffer: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer,
            formatDescription: formatDescription, sampleCount: sampleFrames,
            presentationTimeStamp: CMTime(seconds: ptsSeconds, preferredTimescale: 240_000),
            packetDescriptions: nil, sampleBufferOut: &sampleBuffer)
        return sampleBuffer
    }

    /// Keep the first `channelCount` channels (a wrapper over selectChannels).
    public static func trimChannels(_ sampleBuffer: CMSampleBuffer, to channelCount: Int,
                                    formatCache: inout CMAudioFormatDescription?) -> CMSampleBuffer? {
        selectChannels(sampleBuffer, indices: Array(0..<max(0, channelCount)),
                       formatCache: &formatCache)
    }

    /// Keep an arbitrary set of channels from an interleaved Int16 buffer
    /// (track on/off from the UI). Returns the original buffer if all are
    /// selected; nil if not a single existing channel is selected.
    public static func selectChannels(_ sampleBuffer: CMSampleBuffer, indices: [Int],
                                      formatCache: inout CMAudioFormatDescription?) -> CMSampleBuffer? {
        guard let asbd = interleavedPCM16(of: sampleBuffer) else { return sampleBuffer }
        let sourceChannels = Int(asbd.mChannelsPerFrame)
        let selected = indices.filter { $0 >= 0 && $0 < sourceChannels }.sorted()
        guard !selected.isEmpty else { return nil }
        // everything selected, or nothing to read: the original already is the answer
        guard selected != Array(0..<sourceChannels),
              let samples = interleavedSamples(of: sampleBuffer) else {
            return sampleBuffer
        }

        let frames = samples.count / sourceChannels
        let packed = pack(samples, frames: frames,
                          sourceChannels: sourceChannels, keeping: selected)
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        return packed.withUnsafeBytes { raw -> CMSampleBuffer? in
            guard let base = raw.baseAddress else { return nil }
            return makeSampleBuffer(bytes: base, sampleFrames: frames,
                                    channelCount: selected.count, ptsSeconds: pts,
                                    formatCache: &formatCache)
        }
    }

    /// The stream description, if this really is interleaved 16-bit PCM.
    private static func interleavedPCM16(
        of sampleBuffer: CMSampleBuffer) -> AudioStreamBasicDescription? {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mBitsPerChannel == 16 else { return nil }
        return asbd
    }

    /// A copy of the buffer's samples. Copying costs one packet's worth of
    /// memory and buys a lifetime the caller can reason about — the block
    /// buffer's pointer is only valid while the sample buffer is retained.
    private static func interleavedSamples(
        of sampleBuffer: CMSampleBuffer) -> [Int16]? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer)
        else { return nil }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0,
                                          lengthAtOffsetOut: nil,
                                          totalLengthOut: &length,
                                          dataPointerOut: &pointer) == noErr,
              let pointer, length >= 2 else { return nil }
        return pointer.withMemoryRebound(to: Int16.self, capacity: length / 2) {
            Array(UnsafeBufferPointer(start: $0, count: length / 2))
        }
    }

    /// Re-interleave, keeping only `selected` channels in their given order.
    private static func pack(_ samples: [Int16], frames: Int,
                             sourceChannels: Int, keeping selected: [Int]) -> [Int16] {
        let outChannels = selected.count
        var packed = [Int16](repeating: 0, count: frames * outChannels)
        for frame in 0..<frames {
            for (slot, channel) in selected.enumerated() {
                packed[frame * outChannels + slot] =
                    samples[frame * sourceChannels + channel]
            }
        }
        return packed
    }

    /// Per-channel peak levels in dBFS (-∞ → -100) from an interleaved PCM16 sample buffer.
    public static func peakLevels(of sampleBuffer: CMSampleBuffer) -> [Float] {
        guard let asbd = interleavedPCM16(of: sampleBuffer),
              asbd.mFormatID == kAudioFormatLinearPCM else { return [] }
        let channels = Int(asbd.mChannelsPerFrame)
        guard channels > 0,
              let samples = interleavedSamples(of: sampleBuffer),
              samples.count >= channels else { return [] }
        return peaks(of: samples, channels: channels).map(Self.dBFS)
    }

    /// Largest magnitude per channel.
    private static func peaks(of samples: [Int16], channels: Int) -> [Int16] {
        var peaks = [Int16](repeating: 0, count: channels)
        for frame in 0..<(samples.count / channels) {
            for channel in 0..<channels {
                let value = samples[frame * channels + channel]
                // Int16.min has no positive counterpart — clamp to max
                let magnitude = value == Int16.min ? Int16.max : abs(value)
                if magnitude > peaks[channel] { peaks[channel] = magnitude }
            }
        }
        return peaks
    }

    /// Sample magnitude as dBFS, with silence pinned at the meter floor.
    private static func dBFS(_ peak: Int16) -> Float {
        peak == 0 ? -100 : max(-100, 20 * log10(Float(peak) / Float(Int16.max)))
    }
}
