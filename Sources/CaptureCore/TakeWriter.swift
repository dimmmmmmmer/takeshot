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
    /// Internal rather than private: the audio track's own rules live in
    /// `+Audio`, the way the timecode track's live in `+Timecode` — never
    /// wider than the module.
    var audioInput: AVAssetWriterInput?
    let format: CaptureFormat
    private var appendedFrames = 0

    /// The channel count the take's audio track was opened with — 0 when the
    /// take has no audio track at all.
    ///
    /// LATCHED: it is in the file's header from `startWriting()` on, and
    /// everything appended has to be exactly this wide, which is what `conformed`
    /// below enforces. Public because the pipeline names it in the alarm.
    public private(set) var audioTrackChannels = 0

    /// The timecode track's state. Internal rather than private because the
    /// track itself lives in `+Timecode` — never wider than the module.
    let timecodeInput: AVAssetWriterInput?
    let timecodeFormatDescription: CMTimeCodeFormatDescription?
    let startTimecode: Timecode?
    var tcResyncs: [(pts: CMTime, timecode: Timecode)] = []
    /// How far the timecode track has been WRITTEN, which is not how far the
    /// picture has: the samples are committed as the take runs and lag it by up
    /// to one `timecodeSampleInterval` (see `commitTimecodeSamples`). `.invalid`
    /// until the session starts.
    var tcWrittenUntil = CMTime.invalid
    /// …and the same question for the audio track: the end of the last packet
    /// the audio input accepted, real or padded. `.invalid` until the session
    /// starts, and only ever read while there IS an audio input.
    ///
    /// The third input, and the third one that can hold a fragment shut — see
    /// `padAudioIfNeeded`.
    var audioWrittenUntil = CMTime.invalid
    /// How far this writer has padded silence of its own, and `.invalid` while
    /// it never has. A SEPARATE cursor from the one above so that a take which
    /// is never starved takes exactly the path it took before the backstop
    /// existed: one `isValid` test on a cursor that stays invalid.
    var audioPaddedUntil = CMTime.invalid
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

    /// How often AVAssetWriter closes a fragment.
    public static let fragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)

    /// How long one tc32 sample covers while the take runs.
    ///
    /// A fraction of the fragment interval, and that is measured rather than
    /// tidy: a fragment closes only once every input has passed the boundary, so
    /// a timecode track written at the FRAGMENT cadence is permanently one
    /// boundary short of releasing the fragment it has just reached. Measured on
    /// an abandoned 13 s take: samples every 5 s recover 5 s, samples every 1 s
    /// recover 10 s — the whole picture except the last, still-open fragment.
    /// The cost of the finer cadence is four bytes and one sample-table entry
    /// per second of take.
    public static let timecodeSampleInterval = CMTime(seconds: 1,
                                                      preferredTimescale: 600)

    /// One padded audio packet, in sample frames — 40 ms at the 48 kHz every
    /// audio path in this app runs at.
    ///
    /// The same 40 ms `CapturePipeline.padChunkFrames` pads the external
    /// source's gaps in, stated twice rather than shared because the two pad at
    /// different WIDTHS: the pipeline pads at the source's channel count and
    /// lets the take's mask trim it, this pads at the count the track was
    /// actually opened with.
    static let audioPadFrames = 1920

    /// How far the picture may run ahead of the audio track before this writer
    /// fills the gap itself.
    ///
    /// One second, and it is the same second `timecodeSampleInterval` is: both
    /// tracks then lag the picture by at most that, so what a crash costs is
    /// still the fragment that was open and not a boundary more.
    ///
    /// Deliberately LOOSER than `CapturePipeline.externalStarvationThreshold`
    /// (0.5 s). The pipeline pads a source it can name, counts it and raises the
    /// alarm for it, and it does so on the frame path BEFORE the frame reaches
    /// this writer — so for a USB source that path always fires first and this
    /// one never pre-empts it. This is the backstop under all of them: the rule
    /// it keeps is about the FILE, and no caller can keep it.
    static let audioStarvationLead = CMTime(seconds: 1, preferredTimescale: 600)

    /// How many silence packets ONE video frame may write, for the reason
    /// `CapturePipeline.maximumPadPacketsPerFrame` has the same cap: the frame's
    /// PTS is whatever the board says, and the first hard-won fact about this
    /// hardware is that stream time can jump. Past the cap the cursor is moved
    /// to the frame — the gap is abandoned rather than carried, because one
    /// silence packet AT the picture releases every fragment boundary behind it
    /// at once, while grinding through ten minutes of gap at 32 packets a frame
    /// would leave them shut for the twenty seconds that took.
    static let maximumAudioPadPacketsPerFrame = 32

    /// QuickTime metadata key TakeShot uses to tag its own files
    /// (lets the app tell its takes apart from foreign files in the folder).
    public static let markerKey = "com.takeshot.origin"
    public static let rollKey = "com.takeshot.roll"
    public static let clipKey = "com.takeshot.clip"
    /// The take's REAL frame rate — 23.976, 29.97 — as a decimal string.
    ///
    /// A timecode numbers frames at 24 or 30 and says nothing about whether the
    /// clock behind it runs at 1000/1001 of that; drop-frame flags the 29.97
    /// case and nothing flags 23.976 or 29.97 NON-drop. Every OUT point,
    /// duration-in-frames, ALE FPS and marker position computed from the
    /// timecode alone was therefore counted at 24/30 real frames a second on
    /// those sources: off by one frame every 41 s. The rate is stamped here at
    /// open, like the roll and the clip, so a restored take carries it too.
    public static let frameRateKey = "com.takeshot.framerate"
    /// Name of the LUT baked into the file (absent — the file is clean).
    public static let lutKey = "com.takeshot.lut"

    /// The take's picture is a chroma-key COMPOSITE, and this is what was put
    /// behind the actor — a `ChromaKey.Background` raw value (`checkerboard`,
    /// `color`, `image`, `matte`). Absent means the picture is the camera's.
    ///
    /// A closed vocabulary rather than free text, for the reason `levelsKey` has
    /// one value: this is read by machines as well as people, and "what kind of
    /// deliverable is this" has four answers, not an operator's phrasing of
    /// them. A `matte` take is not a comp at all — it is a black-and-white
    /// channel — and telling those apart in the file is worth the key on its own.
    ///
    /// Unlike `lutKey` this exists for no double-application guard: the key is
    /// never applied on playback, so nothing downstream has to be stopped from
    /// applying it twice. It exists because it is the one fact about the file
    /// that the picture cannot give back — the cyc is gone, and a take that
    /// looks finished is not camera original.
    public static let chromaKeyKey = "com.takeshot.chromakey"

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

        // Timecode track: tc32 samples committed as the take runs (see
        // `commitTimecodeSamples` for why they cannot all wait for finish()).
        let fdesc = try Self.makeTimecodeFormatDescription(startTimecode: startTimecode,
                                                           format: format)
        timecodeFormatDescription = fdesc
        timecodeInput = Self.addTimecodeInput(formatDescription: fdesc, to: writer)

        // Both track inputs MUST be added BEFORE startWriting() below — after it
        // canAdd returns false and the file comes out with no audio track.
        audioInput = Self.addAudioInput(channelCount: audioChannelCount, to: writer)
        audioTrackChannels = audioInput == nil ? 0 : audioChannelCount

        // recoverable files: without fragments a crash/power loss mid-take
        // loses the WHOLE recording (the moov atom is only written in finish)
        writer.movieFragmentInterval = Self.fragmentInterval

        guard writer.startWriting() else {
            throw WriterError.notWritable(writer.status, writer.error)
        }
    }

    /// The writer is still open for business — what a bounded wait for an
    /// input has to stop on, since an input of a writer that has finished or
    /// failed will never become ready again. Named rather than reaching for
    /// `writer` from `+Audio`, so the AVAssetWriter stays behind this type.
    var isWriting: Bool { writer.status == .writing }

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
        guard appendPicture(pixelBuffer, pts: pts) else { return false }
        // …and the audio track, against the same boundary and for the same
        // reason as the timecode samples inside that call. Nothing at all
        // unless a track was opened and then starved (see `padAudioIfNeeded`).
        //
        // On the LIVE path only, which is why it is out here rather than beside
        // the timecode commit. The pre-roll drain appends a whole window of
        // picture BEFORE it offers the sound that goes under it, so a drain that
        // padded would fill the window with silence and then refuse every real
        // pre-roll packet as an overlap — the take's own head, invented.
        padAudioIfNeeded(upTo: pts)
        return true
    }

    /// The picture and the timecode that goes with it, with nothing said about
    /// the audio track. Both append paths go through here.
    private func appendPicture(_ pixelBuffer: CVPixelBuffer, pts: CMTime) -> Bool {
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
        // …and the timecode the picture just reached, one sample interval behind
        // it. Here rather than in `finish()` because a file nobody finishes is
        // exactly what the fragments exist for (see `commitTimecodeSamples`).
        commitTimecodeSamples(upTo: pts)
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
        // Deliberately not the live `append`: the audio backstop must not run
        // while the drain is halfway through the window (see there).
        return appendPicture(pixelBuffer, pts: pts)
    }

    /// Audio packets discarded because the input wasn't ready — sync-critical
    /// gaps that used to vanish silently (video drops were always counted).
    public internal(set) var droppedAudioPackets = 0

    /// Audio packets that had to be re-shaped because the source's channel count
    /// was not the one this take's track was opened with, and the width the
    /// source last sent — the two values the alarm and the log row are built
    /// from (`CapturePipeline.noteAudioConform`).
    public internal(set) var conformedAudioPackets = 0
    public internal(set) var conformedFromChannels = 0
    var conformFormatCache: CMAudioFormatDescription?

    /// Silence this writer padded into its own audio track to keep the file
    /// readable (`padAudioIfNeeded`). Public because only the pipeline can
    /// raise an alarm about it — the same split `conformedAudioPackets` has.
    public internal(set) var paddedAudioPackets = 0
    var padFormatCache: CMAudioFormatDescription?

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
        tcWrittenUntil = pts // the timecode track starts where the picture does
        audioWrittenUntil = pts // …and so does the audio track's own cursor
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
