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
    /// The file's QuickTime metadata: whatever the take carries, the creative
    /// slate, plus the marker that tells TakeShot's own files apart from
    /// foreign ones in the record folder.
    ///
    /// An empty slate contributes nothing at all — a day shot without a script
    /// supervisor must not leave three blank keys in every file.
    static func metadataItems(_ markerMetadata: [String: String],
                              slate: SlateMetadata = .empty) -> [AVMetadataItem] {
        var allMetadata = markerMetadata
        allMetadata[Self.markerKey] = "1"
        if !slate.scene.isEmpty { allMetadata[Self.sceneKey] = slate.scene }
        if slate.shot > 0 { allMetadata[Self.shotKey] = slate.shotText }
        if slate.take > 0 { allMetadata[Self.takeKey] = String(slate.take) }
        return allMetadata.map { key, value in
            mdtaItem(key: key, value: value)
        } + standardSlateItems(slate)
    }

    /// One item in the modern QuickTime metadata ('mdta') key space, which
    /// takes reverse-DNS keys and is what every key above is written in.
    private static func mdtaItem(key: String, value: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.keySpace = .quickTimeMetadata
        item.key = key as NSString
        item.value = value as NSString
        return item
    }

    /// The slate written where an NLE will show it without knowing anything
    /// about TakeShot: as the file's DESCRIPTION, in both QuickTime metadata
    /// containers.
    ///
    /// Both, because the two are read by different tools and neither is a
    /// superset of the other: `com.apple.quicktime.description` is the modern
    /// mdta key Final Cut and QuickTime Player's inspector read, and `©des` is
    /// the classic user-data ('udta') atom that Premiere and the long tail of
    /// older tools read. Writing one of them would leave the slate invisible in
    /// half the rooms this footage lands in; writing both costs a few dozen
    /// bytes in the moov atom and no tracks at all.
    ///
    /// The value is the human digest ("Scene 12A / Shot 2 / Take 3"), never the
    /// three fields concatenated blindly: this is the field a person reads, and
    /// the parseable copy already exists under the namespaced keys.
    private static func standardSlateItems(
        _ slate: SlateMetadata) -> [AVMetadataItem] {
        guard !slate.isEmpty else { return [] }
        let summary = slate.summary
        let mdta = mdtaItem(
            key: AVMetadataKey.quickTimeMetadataKeyDescription.rawValue,
            value: summary)
        let udta = AVMutableMetadataItem()
        udta.keySpace = .quickTimeUserData
        udta.key = AVMetadataKey.quickTimeUserDataKeyDescription.rawValue as NSString
        udta.value = summary as NSString
        return [mdta, udta]
    }

    static func videoSettings(format: CaptureFormat, codec: CaptureCodec,
                              colorTagPreset: String?,
                              displayMetadata: HDRStaticMetadata? = nil)
        -> [String: Any] {
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: codec.avCodecType,
            AVVideoWidthKey: format.width,
            AVVideoHeightKey: format.height,
            // explicit colorimetry (nclc): file and preview are interpreted the same
            AVVideoColorPropertiesKey: ColorTags.videoColorProperties(for: colorTagPreset),
        ]
        var compression: [String: Any] = [:]
        if codec.needsBitrate {
            // visibly good H.264/HEVC for on-set viewing: ~0.12 bpp
            let bitrate = Int(Double(format.width * format.height) * format.frameRate * 0.12)
            compression[AVVideoAverageBitRateKey] = bitrate
            compression[AVVideoExpectedSourceFrameRateKey] =
                Int(format.frameRate.rounded())
        }
        // Static HDR metadata, when the board reported any. These are
        // VideoToolbox property keys rather than AVFoundation ones: AVFoundation
        // publishes no output-settings key for the mastering display or the
        // content light level, and the compression dictionary is the documented
        // route through to the compression session. The nclc tags above say
        // what CURVE the file is in; these say how bright the display it was
        // graded on could go, which is what a colourist needs in order to
        // finish the job the way the DP started it.
        if let displayMetadata, !displayMetadata.isEmpty {
            compression.merge(hdrCompressionProperties(displayMetadata)) { current, _ in
                current
            }
        }
        if !compression.isEmpty {
            videoSettings[AVVideoCompressionPropertiesKey] = compression
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
