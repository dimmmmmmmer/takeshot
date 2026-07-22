import CoreMedia
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
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mBitsPerChannel == 16 else { return sampleBuffer }
        let sourceChannels = Int(asbd.mChannelsPerFrame)
        let selected = indices.filter { $0 >= 0 && $0 < sourceChannels }.sorted()
        guard !selected.isEmpty else { return nil }
        guard selected != Array(0..<sourceChannels),
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return sampleBuffer
        }

        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0,
                                          lengthAtOffsetOut: nil, totalLengthOut: &length,
                                          dataPointerOut: &pointer) == noErr,
              let pointer else { return sampleBuffer }

        let frames = length / 2 / sourceChannels
        let outChannels = selected.count
        var packed = [Int16](repeating: 0, count: frames * outChannels)
        pointer.withMemoryRebound(to: Int16.self, capacity: length / 2) { samples in
            for frame in 0..<frames {
                for (slot, channel) in selected.enumerated() {
                    packed[frame * outChannels + slot] =
                        samples[frame * sourceChannels + channel]
                }
            }
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        return packed.withUnsafeBytes { raw -> CMSampleBuffer? in
            guard let base = raw.baseAddress else { return nil }
            return makeSampleBuffer(bytes: base, sampleFrames: frames,
                                    channelCount: outChannels, ptsSeconds: pts,
                                    formatCache: &formatCache)
        }
    }

    /// Per-channel peak levels in dBFS (-∞ → -100) from an interleaved PCM16 sample buffer.
    public static func peakLevels(of sampleBuffer: CMSampleBuffer) -> [Float] {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM, asbd.mBitsPerChannel == 16,
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer)
        else { return [] }

        let channels = Int(asbd.mChannelsPerFrame)
        guard channels > 0 else { return [] }

        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0,
                                          lengthAtOffsetOut: nil, totalLengthOut: &length,
                                          dataPointerOut: &pointer) == noErr,
              let pointer, length >= 2 * channels
        else { return [] }

        var peaks = [Int16](repeating: 0, count: channels)
        pointer.withMemoryRebound(to: Int16.self, capacity: length / 2) { samples in
            let frameCount = length / 2 / channels
            for frame in 0..<frameCount {
                for channel in 0..<channels {
                    let value = samples[frame * channels + channel]
                    let magnitude = value == Int16.min ? Int16.max : abs(value)
                    if magnitude > peaks[channel] { peaks[channel] = magnitude }
                }
            }
        }
        return peaks.map { peak in
            peak == 0 ? -100 : max(-100, 20 * log10(Float(peak) / Float(Int16.max)))
        }
    }
}
