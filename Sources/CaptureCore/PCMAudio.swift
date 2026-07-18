import CoreMedia
import Foundation

/// Утилиты для PCM 16-бит interleaved аудио (общие для бэкендов и конвейера).
public enum PCMAudio {
    /// CMSampleBuffer из сырых interleaved Int16-сэмплов, 48 кГц.
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

    /// Пиковые уровни каналов в dBFS (-∞ → -100) из PCM16 interleaved сэмпл-буфера.
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
