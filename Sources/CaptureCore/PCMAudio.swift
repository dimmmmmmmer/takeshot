@preconcurrency import CoreMedia
import Foundation

/// Utilities for 16-bit interleaved PCM audio (shared by backends and pipeline).
public enum PCMAudio {
    /// A CMSampleBuffer from raw interleaved Int16 samples, 48 kHz.
    public static func makeSampleBuffer(bytes: UnsafeRawPointer, sampleFrames: Int,
                                        channelCount: Int, ptsSeconds: Double,
                                        formatCache: inout CMAudioFormatDescription?) -> CMSampleBuffer? {
        // The cache exists so a 40 ms packet does not rebuild a description, and
        // it used to be keyed on nothing at all: a cached one was reused whatever
        // channel count the caller asked for. A source that changed its own count
        // then produced buffers DESCRIBING the old count and CARRYING the new
        // one, which is mis-interleaved audio in the file rather than an error
        // anywhere. The pipeline resets its caches on the two changes it is told
        // about (the operator's channel mask, a source switch) and cannot reset
        // them for the one it only learns from a packet.
        if !Self.describes(formatCache, channels: channelCount) {
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

    /// How many channels an interleaved 16-bit PCM buffer carries; 0 when it is
    /// not one of those at all.
    public static func channelCount(of sampleBuffer: CMSampleBuffer) -> Int {
        guard let asbd = interleavedPCM16(of: sampleBuffer) else { return 0 }
        return Int(asbd.mChannelsPerFrame)
    }

    /// The same samples at EXACTLY `channelCount` channels: extra channels
    /// dropped, missing ones silent, the ones in common kept where they are.
    ///
    /// `trimChannels` below can only narrow, and narrowing is only half of what
    /// a source that changed its own count can do to a track whose width is
    /// already latched (see `CapturePipeline.recordAudio`). Returns the original
    /// buffer when it is already the right width, so the case that happens on
    /// every packet costs one comparison.
    public static func conformChannels(
        _ sampleBuffer: CMSampleBuffer, to channelCount: Int,
        formatCache: inout CMAudioFormatDescription?) -> CMSampleBuffer? {
        guard channelCount > 0, let asbd = interleavedPCM16(of: sampleBuffer)
        else { return nil }
        let sourceChannels = Int(asbd.mChannelsPerFrame)
        guard sourceChannels != channelCount else { return sampleBuffer }
        guard sourceChannels > 0,
              let samples = interleavedSamples(of: sampleBuffer) else { return nil }

        let frames = samples.count / sourceChannels
        let shared = min(sourceChannels, channelCount)
        var packed = [Int16](repeating: 0, count: frames * channelCount)
        for frame in 0..<frames {
            for channel in 0..<shared {
                packed[frame * channelCount + channel] =
                    samples[frame * sourceChannels + channel]
            }
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        return packed.withUnsafeBytes { raw -> CMSampleBuffer? in
            guard let base = raw.baseAddress else { return nil }
            return makeSampleBuffer(bytes: base, sampleFrames: frames,
                                    channelCount: channelCount, ptsSeconds: pts,
                                    formatCache: &formatCache)
        }
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
        let selected = indices.filter { (0..<sourceChannels).contains($0) }.sorted()
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

    /// Whether a cached description really describes this many channels — the
    /// cache key `makeSampleBuffer` above did not have. nil is "no cache", which
    /// answers false and builds one.
    private static func describes(_ description: CMAudioFormatDescription?,
                                  channels: Int) -> Bool {
        guard let description,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(
                  description)?.pointee else { return false }
        return Int(asbd.mChannelsPerFrame) == channels
    }

    /// The stream description, if this really is interleaved 16-bit PCM.
    /// Internal rather than private: the meters in `+Peaks` read it too.
    static func interleavedPCM16(
        of sampleBuffer: CMSampleBuffer) -> AudioStreamBasicDescription? {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mBitsPerChannel == 16 else { return nil }
        return asbd
    }

    /// A copy of the buffer's samples. Copying costs one packet's worth of
    /// memory and buys a lifetime the caller can reason about — the block
    /// buffer's pointer is only valid while the sample buffer is retained.
    ///
    /// Public because the outgoing legs off the pipeline's stereo tap live in
    /// TakeShotKit and every one of them starts by reading a packet's samples:
    /// the AAC encoder here, planar float for NDI at the seam. The copy is what
    /// makes that safe to hand across a queue at all, which is the same reason
    /// it exists for the callers inside this module.
    public static func interleavedSamples(
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
}
