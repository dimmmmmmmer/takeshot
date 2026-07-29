@preconcurrency import AVFoundation
import Foundation

/// Everything the writer has to have in place BEFORE `startWriting()`: the
/// file metadata, the three inputs' settings, and the timecode format
/// description. Static factories rather than methods, because the initializer
/// needs these values before the instance exists.
///
/// Split out of TakeWriter, whose initializer had grown past 90 lines.
extension TakeWriter {
    /// The file's QuickTime metadata: whatever the take carries, plus the
    /// marker that tells TakeShot's own files apart from foreign ones in the
    /// record folder.
    static func metadataItems(_ markerMetadata: [String: String]) -> [AVMetadataItem] {
        var metadataItems: [AVMetadataItem] = []
        var allMetadata = markerMetadata
        allMetadata[Self.markerKey] = "1"
        for (key, value) in allMetadata {
            let item = AVMutableMetadataItem()
            item.keySpace = .quickTimeMetadata
            item.key = key as NSString
            item.value = value as NSString
            metadataItems.append(item)
        }
        return metadataItems
    }

    static func videoSettings(format: CaptureFormat, codec: CaptureCodec,
                              colorTagPreset: String?) -> [String: Any] {
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: codec.avCodecType,
            AVVideoWidthKey: format.width,
            AVVideoHeightKey: format.height,
            // explicit colorimetry (nclc): file and preview are interpreted the same
            AVVideoColorPropertiesKey: ColorTags.videoColorProperties(for: colorTagPreset),
        ]
        if codec.needsBitrate {
            // visibly good H.264/HEVC for on-set viewing: ~0.12 bpp
            let bitrate = Int(Double(format.width * format.height) * format.frameRate * 0.12)
            videoSettings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: Int(format.frameRate.rounded()),
            ]
        }
        return videoSettings
    }

    /// PCM 48k/16-bit; the channel count comes from the pipeline.
    static func audioSettings(channelCount: Int) -> [String: Any] {
        var audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        // for >2 channels LPCM requires a channel layout — without it append
        // crashes the process (NSException). Discrete layout by channel count.
        if channelCount > 2 {
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag =
                kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channelCount)
            audioSettings[AVChannelLayoutKey] =
                Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
        }
        return audioSettings
    }

    /// The tc32 format description for the take's timecode track, or nil when
    /// the take has no start timecode and gets no track at all.
    static func makeTimecodeFormatDescription(
        startTimecode: Timecode?,
        format: CaptureFormat) throws -> CMTimeCodeFormatDescription? {
        guard let tc = startTimecode else { return nil }
        var fdesc: CMTimeCodeFormatDescription?
        let frameDuration = CMTime(value: 1000, timescale: CMTimeScale(format.frameRate * 1000))
        let status = CMTimeCodeFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            timeCodeFormatType: kCMTimeCodeFormatType_TimeCode32,
            frameDuration: frameDuration,
            frameQuanta: UInt32(tc.fps),
            flags: tc.isDropFrame ? kCMTimeCodeFlag_DropFrame | kCMTimeCodeFlag_24HourMax
                                  : kCMTimeCodeFlag_24HourMax,
            extensions: nil,
            formatDescriptionOut: &fdesc)
        guard status == noErr, let fdesc else { throw WriterError.timecodeTrackFailed }
        return fdesc
    }

    /// One tc32 sample covering [from, until). Internal rather than private:
    /// `finish()` calls it from the other file.
    func appendTimecodeSample(input: AVAssetWriterInput,
                              formatDescription: CMTimeCodeFormatDescription,
                              timecode: Timecode,
                              from: CMTime, until: CMTime) {
        // tc32: one big-endian UInt32 with the start frame number
        var frameNumber = UInt32(clamping: timecode.frameNumber).bigEndian
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: 4,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: 4, flags: 0, blockBufferOut: &blockBuffer) == noErr,
            let blockBuffer else { return }
        withUnsafeBytes(of: &frameNumber) { bytes in
            _ = CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!, blockBuffer: blockBuffer,
                offsetIntoDestination: 0, dataLength: 4)
        }

        var timing = CMSampleTimingInfo(
            duration: CMTimeSubtract(until, from),
            presentationTimeStamp: from,
            decodeTimeStamp: .invalid)
        var sampleSize = 4
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: formatDescription,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer) == noErr, let sampleBuffer else { return }
        // several anchors append back to back — wait out the input queue
        let deadline = Date().addingTimeInterval(0.5)
        while !input.isReadyForMoreMediaData, Date() < deadline {
            usleep(1000)
        }
        input.append(sampleBuffer)
    }
}
