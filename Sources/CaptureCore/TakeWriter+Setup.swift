@preconcurrency import AVFoundation
import Foundation

/// Everything the writer has to have in place BEFORE `startWriting()`: the
/// file metadata and the two track settings dictionaries. Static factories
/// rather than methods, because the initializer needs these values before the
/// instance exists. (The timecode track's own setup is in `+Timecode`, with the
/// rest of that track.)
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
}
