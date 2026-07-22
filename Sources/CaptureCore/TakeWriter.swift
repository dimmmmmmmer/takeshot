import AVFoundation
import CoreVideo
import Foundation

/// Writes one take to a .mov: video in the chosen codec, PCM audio passthrough,
/// a timecode track with the take's start TC.
///
/// Lifecycle: init → append*(…) → finish(). One instance = one file.
public final class TakeWriter {
    public enum WriterError: Error, LocalizedError {
        case cannotCreateWriter(Error)
        case notWritable(AVAssetWriter.Status, Error?)
        case timecodeTrackFailed

        public var errorDescription: String? {
            switch self {
            case .cannotCreateWriter(let error):
                return "Cannot create writer: \(error.localizedDescription)"
            case .notWritable(let status, let error):
                let reason = error?.localizedDescription ?? "status \(status.rawValue)"
                return "Writer failed: \(reason)"
            case .timecodeTrackFailed:
                return "Failed to create timecode track"
            }
        }
    }

    public let url: URL

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor
    private var audioInput: AVAssetWriterInput?
    private let timecodeInput: AVAssetWriterInput?
    private let timecodeFormatDescription: CMTimeCodeFormatDescription?

    private let format: CaptureFormat
    private let startTimecode: Timecode?
    private var sessionStarted = false
    private var firstPTS = CMTime.invalid
    private var lastPTS = CMTime.invalid
    private var appendedFrames = 0

    public var durationSeconds: Double {
        guard firstPTS.isValid, lastPTS.isValid else { return 0 }
        let frameDuration = 1.0 / format.frameRate
        return CMTimeSubtract(lastPTS, firstPTS).seconds + frameDuration
    }

    /// QuickTime metadata key TakeShot uses to tag its own files
    /// (lets the app tell its takes apart from foreign files in the folder).
    public static let markerKey = "com.takeshot.origin"
    public static let rollKey = "com.takeshot.roll"
    public static let clipKey = "com.takeshot.clip"
    /// Name of the LUT baked into the file (absent — the file is clean).
    public static let lutKey = "com.takeshot.lut"

    public init(url: URL, format: CaptureFormat, codec: CaptureCodec,
                startTimecode: Timecode?,
                markerMetadata: [String: String] = [:],
                colorTagPreset: String? = nil,
                audioChannelCount: Int = 0) throws {
        self.url = url
        self.format = format
        self.startTimecode = startTimecode

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        } catch {
            throw WriterError.cannotCreateWriter(error)
        }

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
        writer.metadata = metadataItems

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
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput, sourcePixelBufferAttributes: nil)
        writer.add(videoInput)

        // Timecode track: one tc32 sample for the whole take, added in finish().
        if let tc = startTimecode {
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
            timecodeFormatDescription = fdesc
            let input = AVAssetWriterInput(mediaType: .timecode, outputSettings: nil,
                                           sourceFormatHint: fdesc)
            input.expectsMediaDataInRealTime = false
            timecodeInput = input
            writer.add(input)
        } else {
            timecodeInput = nil
            timecodeFormatDescription = nil
        }

        // The audio input MUST be added BEFORE startWriting() — otherwise canAdd
        // returns false and the file has no audio track. The format is known
        // up front (PCM 48k/16-bit, channel count comes from the pipeline).
        if audioChannelCount > 0 {
            var audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: audioChannelCount,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            // for >2 channels LPCM requires a channel layout — without it append
            // crashes the process (NSException). Discrete layout by channel count.
            if audioChannelCount > 2 {
                var layout = AudioChannelLayout()
                layout.mChannelLayoutTag =
                    kAudioChannelLayoutTag_DiscreteInOrder | UInt32(audioChannelCount)
                audioSettings[AVChannelLayoutKey] =
                    Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
            }
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        guard writer.startWriting() else {
            throw WriterError.notWritable(writer.status, writer.error)
        }
    }

    /// A video frame. `pts` is the presentation time on the capture timeline (any
    /// base; the session starts from the first frame passed in).
    /// Returns false if the frame was dropped (encoder/disk can't keep up) —
    /// acceptable during live capture; the caller keeps the drop counter.
    @discardableResult
    public func append(pixelBuffer: CVPixelBuffer, pts: CMTime) -> Bool {
        startSessionIfNeeded(at: pts)
        guard videoInput.isReadyForMoreMediaData else { return false }
        guard pixelBufferAdaptor.append(pixelBuffer, withPresentationTime: pts) else {
            return false
        }
        appendedFrames += 1
        lastPTS = pts
        return true
    }

    /// PCM audio from the capture board. The input is already created in init (before startWriting).
    public func append(audioSampleBuffer: CMSampleBuffer) {
        guard sessionStarted, let audioInput, audioInput.isReadyForMoreMediaData else { return }
        audioInput.append(audioSampleBuffer)
    }

    /// Finish the take. Returns the URL of the finished file.
    public func finish() async throws -> URL {
        if let timecodeInput, let fdesc = timecodeFormatDescription,
           let tc = startTimecode, sessionStarted {
            appendTimecodeSample(input: timecodeInput, formatDescription: fdesc, timecode: tc)
        }
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        timecodeInput?.markAsFinished()
        if lastPTS.isValid {
            let frameDuration = CMTime(value: 1000, timescale: CMTimeScale(format.frameRate * 1000))
            writer.endSession(atSourceTime: CMTimeAdd(lastPTS, frameDuration))
        }
        await writer.finishWriting()
        if writer.status == .failed {
            throw WriterError.notWritable(writer.status, writer.error)
        }
        return url
    }

    /// Cancel and delete the unfinished file.
    public func cancel() {
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - private

    private func startSessionIfNeeded(at pts: CMTime) {
        guard !sessionStarted else { return }
        sessionStarted = true
        firstPTS = pts
        writer.startSession(atSourceTime: pts)
    }

    private func appendTimecodeSample(input: AVAssetWriterInput,
                                      formatDescription: CMTimeCodeFormatDescription,
                                      timecode: Timecode) {
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

        let frameDuration = CMTime(value: 1000,
                                   timescale: CMTimeScale(format.frameRate * 1000))
        var timing = CMSampleTimingInfo(
            duration: CMTimeSubtract(CMTimeAdd(lastPTS, frameDuration), firstPTS),
            presentationTimeStamp: firstPTS,
            decodeTimeStamp: .invalid)
        var sampleSize = 4
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: formatDescription,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer) == noErr, let sampleBuffer else { return }
        input.append(sampleBuffer)
    }
}

extension CaptureCodec {
    var avCodecType: AVVideoCodecType {
        switch self {
        case .proResProxy: return .proRes422Proxy
        case .proResLT: return .proRes422LT
        case .proRes422: return .proRes422
        case .proResHQ: return .proRes422HQ
        case .h264: return .h264
        case .hevc: return .hevc
        }
    }

    var needsBitrate: Bool {
        switch self {
        case .h264, .hevc: return true
        default: return false
        }
    }
}
