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
    private let format: CaptureFormat
    private var appendedFrames = 0

    /// The timecode track's state. Internal rather than private because the
    /// track itself lives in `+Timecode` — never wider than the module.
    let timecodeInput: AVAssetWriterInput?
    let timecodeFormatDescription: CMTimeCodeFormatDescription?
    let startTimecode: Timecode?
    var tcResyncs: [(pts: CMTime, timecode: Timecode)] = []
    /// The session's span, which the timecode samples are placed against.
    var sessionStarted = false
    var firstPTS = CMTime.invalid
    var lastPTS = CMTime.invalid

    public var durationSeconds: Double {
        guard firstPTS.isValid, lastPTS.isValid else { return 0 }
        return CMTimeSubtract(lastPTS, firstPTS).seconds + 1.0 / format.frameRate
    }

    /// One frame at the take's rate. The 1000/1000 scaling keeps a fractional
    /// rate (23.976, 29.97) exact in the timescale instead of rounding it.
    var frameDuration: CMTime { Self.frameDuration(at: format.frameRate) }

    static func frameDuration(at frameRate: Double) -> CMTime {
        CMTime(value: 1000, timescale: CMTimeScale(frameRate * 1000))
    }

    /// QuickTime metadata key TakeShot uses to tag its own files
    /// (lets the app tell its takes apart from foreign files in the folder).
    public static let markerKey = "com.takeshot.origin"
    public static let rollKey = "com.takeshot.roll"
    public static let clipKey = "com.takeshot.clip"
    /// Name of the LUT baked into the file (absent — the file is clean).
    public static let lutKey = "com.takeshot.lut"

    /// What the picture codes in this file MEAN — `wireValue` when they are the
    /// camera's studio-swing wire codes, absent when they are display values
    /// that fill the scale.
    ///
    /// The distinction is not cosmetic and it is not guessable from the file:
    /// both kinds decode to a full-range buffer, and shown without expanding it
    /// a studio-swing one is 6 % of washed black. It is written per take rather
    /// than assumed per app version because takes shot before the record path
    /// started carrying wire codes are still on the operator's disk, and
    /// expanding those a second time would crush the very shadows this exists
    /// to protect.
    public static let levelsKey = "com.takeshot.levels"
    /// The one value `levelsKey` is ever written with.
    public static let wireValue = "wire"

    /// Whether a file's picture must be expanded from studio swing before it is
    /// shown next to a live signal. Reads the metadata an asset was loaded
    /// with; anything else — a foreign file, an older take — is left alone.
    public static func carriesWireCodes(_ metadata: [AVMetadataItem]) async -> Bool {
        guard let item = metadata.first(where: {
            ($0.key as? String) == levelsKey
        }) else { return false }
        return (try? await item.load(.stringValue)) == wireValue
    }

    // MARK: - creative (slate) keys
    //
    // QuickTime has no standard key for scene, shot or take — the mdta
    // vocabulary Apple publishes (`com.apple.quicktime.*`) covers title,
    // description, comment, author, creation date and camera identity, and
    // stops there. So the machine-precise values go into TakeShot's OWN
    // reverse-DNS namespace, exactly like the roll and clip keys above, and a
    // human-readable digest of them goes into the standard description keys
    // (see `standardSlateItems`) where an NLE will actually surface it.
    /// Scene, as the script supervisor writes it.
    public static let sceneKey = "com.takeshot.scene"
    /// Shot / setup letter inside the scene.
    public static let shotKey = "com.takeshot.shot"
    /// Take number WITHIN the scene — not the clip counter in `clipKey`.
    public static let takeKey = "com.takeshot.take"

    public init(url: URL, format: CaptureFormat, codec: CaptureCodec,
                startTimecode: Timecode?,
                markerMetadata: [String: String] = [:],
                slate: SlateMetadata = .empty,
                colorTagPreset: String? = nil,
                displayMetadata: HDRStaticMetadata? = nil,
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

        writer.metadata = Self.metadataItems(markerMetadata, slate: slate)

        videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: Self.videoSettings(format: format, codec: codec,
                                               colorTagPreset: colorTagPreset,
                                               displayMetadata: displayMetadata))
        videoInput.expectsMediaDataInRealTime = true
        pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput, sourcePixelBufferAttributes: nil)
        writer.add(videoInput)

        // Timecode track: one tc32 sample for the whole take, added in finish().
        let fdesc = try Self.makeTimecodeFormatDescription(startTimecode: startTimecode,
                                                           format: format)
        timecodeFormatDescription = fdesc
        timecodeInput = Self.addTimecodeInput(formatDescription: fdesc, to: writer)

        // Both track inputs MUST be added BEFORE startWriting() below — after it
        // canAdd returns false and the file comes out with no audio track.
        audioInput = Self.addAudioInput(channelCount: audioChannelCount, to: writer)

        // recoverable files: without fragments a crash/power loss mid-take
        // loses the WHOLE recording (the moov atom is only written in finish)
        writer.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)

        guard writer.startWriting() else {
            throw WriterError.notWritable(writer.status, writer.error)
        }
    }

    /// The take's audio track, or nil when the source has no channels or the
    /// writer refuses the input. The format is known up front — PCM 48k/16-bit,
    /// channel count from the pipeline.
    private static func addAudioInput(channelCount: Int,
                                      to writer: AVAssetWriter) -> AVAssetWriterInput? {
        guard channelCount > 0 else { return nil }
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: Self.audioSettings(channelCount: channelCount))
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { return nil }
        writer.add(input)
        return input
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

    /// A buffered (pre-roll) audio packet — the counterpart of
    /// `appendBuffered(pixelBuffer:pts:)` and for the same reason.
    ///
    /// The pre-roll drain hands over a whole window's worth of packets in one
    /// burst, which outruns the audio input exactly as the picture burst outruns
    /// the video one. Offered through `append` they were simply refused and
    /// counted: measured on a 20-frame pre-roll, 15 of a take's ~20 pre-roll
    /// packets were dropped, so "pre-roll carries audio as well as picture" held
    /// for the first fifth of the window and the rest of the take's head was
    /// silent — reported afterwards as "audio packet(s) dropped", which reads
    /// like a busy disk rather than the head of the take.
    ///
    /// The wait shares the video drain's deadline, so the whole drain still costs
    /// the capture queue one bounded stall and not two.
    @discardableResult
    public func appendBuffered(audioSampleBuffer: CMSampleBuffer,
                               deadline: Date) -> Bool {
        guard sessionStarted, let audioInput else { return false }
        while !audioInput.isReadyForMoreMediaData, writer.status == .writing,
              Date() < deadline {
            usleep(2000)
        }
        append(audioSampleBuffer: audioSampleBuffer)
        return true
    }

    /// Finish the take. Returns the URL of the finished file.
    public func finish() async throws -> URL {
        // finishing with zero samples fails inside AVAssetWriter (-11800) and
        // leaves a 0-byte file — cancel and report a meaningful error instead
        guard appendedFrames > 0 else {
            cancel()
            throw WriterError.emptyTake
        }
        appendTimecodeTrack()
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        timecodeInput?.markAsFinished()
        if lastPTS.isValid {
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
        case .proRes4444: return .proRes4444
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
