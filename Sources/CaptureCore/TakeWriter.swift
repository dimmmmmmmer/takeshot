@preconcurrency import AVFoundation
@preconcurrency import CoreVideo
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
        case emptyTake

        public var errorDescription: String? {
            switch self {
            case .cannotCreateWriter(let error):
                return "Cannot create writer: \(error.localizedDescription)"
            case .notWritable(let status, let error):
                let reason = error?.localizedDescription ?? "status \(status.rawValue)"
                return "Writer failed: \(reason)"
            case .timecodeTrackFailed:
                return "Failed to create timecode track"
            case .emptyTake:
                return "Take contained no video frames"
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

        writer.metadata = Self.metadataItems(markerMetadata)

        videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: Self.videoSettings(format: format, codec: codec,
                                               colorTagPreset: colorTagPreset))
        videoInput.expectsMediaDataInRealTime = true
        pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput, sourcePixelBufferAttributes: nil)
        writer.add(videoInput)

        // Timecode track: one tc32 sample for the whole take, added in finish().
        let fdesc = try Self.makeTimecodeFormatDescription(startTimecode: startTimecode,
                                                           format: format)
        timecodeFormatDescription = fdesc
        if let fdesc {
            let input = AVAssetWriterInput(mediaType: .timecode, outputSettings: nil,
                                           sourceFormatHint: fdesc)
            input.expectsMediaDataInRealTime = false
            timecodeInput = input
            writer.add(input)
        } else {
            timecodeInput = nil
        }

        // The audio input MUST be added BEFORE startWriting() — otherwise canAdd
        // returns false and the file has no audio track. The format is known
        // up front (PCM 48k/16-bit, channel count comes from the pipeline).
        if audioChannelCount > 0 {
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: Self.audioSettings(channelCount: audioChannelCount))
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        // recoverable files: without fragments a crash/power loss mid-take
        // loses the WHOLE recording (the moov atom is only written in finish)
        writer.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)

        guard writer.startWriting() else {
            throw WriterError.notWritable(writer.status, writer.error)
        }
    }

    /// True once AVAssetWriter has failed permanently. A dropped frame on its
    /// own is routine back-pressure; this is the difference between "the encoder
    /// is behind" and "nothing will ever be written again", and the caller has
    /// to close the take instead of counting drops forever.
    public var hasFailed: Bool { writer.status == .failed }

    /// Why the writer died, for the operator-facing alarm.
    public var failureReason: String {
        writer.error?.localizedDescription ?? "writer failed"
    }

    /// A video frame. `pts` is the presentation time on the capture timeline (any
    /// base; the session starts from the first frame passed in).
    /// Returns false if the frame was dropped (encoder/disk can't keep up) —
    /// acceptable during live capture; the caller keeps the drop counter.
    @discardableResult
    public func append(pixelBuffer: CVPixelBuffer, pts: CMTime) -> Bool {
        // a duplicate/backwards PTS puts AVAssetWriter into .failed permanently —
        // dropping the frame keeps the take alive if the backend misdelivers PTS
        if lastPTS.isValid, pts <= lastPTS { return false }
        startSessionIfNeeded(at: pts)
        guard videoInput.isReadyForMoreMediaData else { return false }
        guard pixelBufferAdaptor.append(pixelBuffer, withPresentationTime: pts) else {
            return false
        }
        appendedFrames += 1
        lastPTS = pts
        return true
    }

    /// A buffered (pre-roll) frame: unlike live frames these arrive in a burst
    /// that outruns the encoder queue, so wait briefly for readiness instead of
    /// dropping — they are historical frames, timing is not critical.
    @discardableResult
    public func appendBuffered(pixelBuffer: CVPixelBuffer, pts: CMTime,
                               deadline: Date = Date().addingTimeInterval(0.5)) -> Bool {
        while !videoInput.isReadyForMoreMediaData, writer.status == .writing,
              Date() < deadline {
            usleep(2000)
        }
        return append(pixelBuffer: pixelBuffer, pts: pts)
    }

    /// Audio packets discarded because the input wasn't ready — sync-critical
    /// gaps that used to vanish silently (video drops were always counted).
    public private(set) var droppedAudioPackets = 0

    /// PCM audio from the capture board. The input is already created in init (before startWriting).
    public func append(audioSampleBuffer: CMSampleBuffer) {
        guard sessionStarted, let audioInput else { return }
        guard audioInput.isReadyForMoreMediaData else {
            droppedAudioPackets += 1
            return
        }
        audioInput.append(audioSampleBuffer)
    }

    /// A timecode re-anchor mid-take: the camera's Rec Run TC stood still when
    /// the take started and began running at `timecode` on the frame at `pts` —
    /// an extra tc32 sample from that frame keeps the file frame-accurate
    /// against the camera original in the overlapping region.
    public func addTimecodeResync(timecode: Timecode, at pts: CMTime) {
        guard startTimecode != nil, sessionStarted, pts > firstPTS,
              tcResyncs.count < 32 else { return }
        tcResyncs.append((pts: pts, timecode: timecode))
    }

    private var tcResyncs: [(pts: CMTime, timecode: Timecode)] = []

    /// Finish the take. Returns the URL of the finished file.
    public func finish() async throws -> URL {
        // finishing with zero samples fails inside AVAssetWriter (-11800) and
        // leaves a 0-byte file — cancel and report a meaningful error instead
        guard appendedFrames > 0 else {
            cancel()
            throw WriterError.emptyTake
        }
        if let timecodeInput, let fdesc = timecodeFormatDescription,
           let tc = startTimecode, sessionStarted {
            let frameDuration = CMTime(value: 1000,
                                       timescale: CMTimeScale(format.frameRate * 1000))
            let end = CMTimeAdd(lastPTS, frameDuration)
            var anchors: [(pts: CMTime, timecode: Timecode)] = [(firstPTS, tc)]
            anchors.append(contentsOf: tcResyncs.filter {
                $0.pts > firstPTS && $0.pts < end
            })
            for (index, anchor) in anchors.enumerated() {
                let next = index + 1 < anchors.count ? anchors[index + 1].pts : end
                appendTimecodeSample(input: timecodeInput, formatDescription: fdesc,
                                     timecode: anchor.timecode,
                                     from: anchor.pts, until: next)
            }
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
