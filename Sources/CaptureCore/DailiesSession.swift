@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import Foundation

/// Why one dailies item stopped early. Cancel covers both Stop and Skip —
/// the difference is which items after this one still run, and that is the
/// queue's decision, not the item's.
enum DailiesAbort: Error {
    case cancelled
    case failed(String)
}

/// What the probe learned about one source before anything opens: the tracks,
/// the rates, the raster the daily will be, and the timecode timeline the
/// burn-in runs on. Gathered in one async pass so the session opener and the
/// composer are both synchronous over settled facts.
struct DailiesSourceFacts {
    let asset: AVURLAsset
    let videoTrack: AVAssetTrack
    let audioTracks: [AVAssetTrack]
    /// The VIDEO rate (23.976, 25…), which also paces the TC clock.
    let frameRate: Double
    /// For the progress bar; the loop itself just reads until the file ends.
    let framesTotal: Int
    let outputSize: CGSize
    /// nil — the timecode burn-in is off and no clock is computed at all.
    let timeline: DailiesTimeline?
    /// What the SOURCE FILE says its codes mean, read from its own format
    /// description and never from live state. A daily is made from a finished
    /// file that may have been shot in an earlier session, on another machine,
    /// off another camera — the wire that produced it is long gone, and the
    /// only thing that still knows what its codes mean is the take itself.
    let colorimetry: WireColorimetry
    /// The one 256-entry lookup the decoded picture goes through on its way
    /// into the proxy: `StudioSwing.playbackTable`, the SAME table the player
    /// applies to the same file. Not a second tone map — a proxy that
    /// disagrees with the review it came from is worse than no proxy.
    ///
    /// nil when the file needs nothing at all, which is every SDR take with no
    /// levels key, every foreign clip, and every take from before either tag
    /// existed.
    let levels: [UInt8]?
    /// The source file's OWN metadata, filtered into the proxy by
    /// `carriedMetadata`.
    ///
    /// The array was already being loaded here to answer the levels question
    /// and was then thrown away, so every key the take carried — the roll, the
    /// clip, the scene/shot/take, the description an NLE shows — was lost in
    /// the proxy (owner: "ну и конечно важно чтоб мета вся возможная из
    /// исходника сохранялась").
    let metadata: [AVMetadataItem]
    /// The look already baked into the SOURCE's pixels, or nil.
    ///
    /// A take recorded with the look burned in carries the name of it, and the
    /// player refuses to apply a viewing look over one that is already in the
    /// picture. A daily has to refuse for the same reason and with more at
    /// stake: a second grade is permanent in the proxy.
    let bakedLook: String?

    static func probe(item: DailiesItem, burnins: DailiesBurnins,
                      desqueeze: Double = 1) async throws -> DailiesSourceFacts {
        let asset = AVURLAsset(url: item.source)
        guard let track = try? await asset.tracks(ofType: .video).first else {
            throw DailiesAbort.failed(
                "no video track: \(item.source.lastPathComponent)")
        }
        let naturalSize = (try? await track.load(.naturalSize)) ?? .zero
        let nominalRate = (try? await track.load(.nominalFrameRate)) ?? 0
        // 25 as the last resort only: a rate of 0 would freeze the TC clock.
        let frameRate = nominalRate > 0 ? Double(nominalRate) : 25
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let colorimetry = await ColorTags.colorimetry(of: asset)
        // BOTH questions the player asks, asked here the same way: the levels
        // key says whether the codes are studio swing, the transfer tag says
        // what curve they are on, and the two compose into one table.
        let metadata: [AVMetadataItem] = (try? await asset.load(.metadata)) ?? []
        let wireCodes = await TakeWriter.carriesWireCodes(metadata)
        let baked = await TakeWriter.bakedLookName(metadata)

        return DailiesSourceFacts(
            asset: asset, videoTrack: track,
            audioTracks: (try? await asset.tracks(ofType: .audio)) ?? [],
            frameRate: frameRate,
            framesTotal: max(1, Int((duration * frameRate).rounded())),
            outputSize: DailiesEngine.outputSize(for: naturalSize,
                                                 desqueeze: desqueeze),
            timeline: burnins.timecode
                ? await DailiesEngine.timeline(for: asset, item: item,
                                               frameRate: frameRate) : nil,
            colorimetry: colorimetry,
            levels: StudioSwing.playbackTable(wireCodes: wireCodes,
                                              transfer: colorimetry.transfer),
            metadata: metadata, bakedLook: baked)
    }
}

/// Everything one open transcode holds: the reader, the writer and their
/// track ends. Grouped so the frame loop's helpers take one parameter, and
/// so cleanup can reach both from any failure point.
struct DailiesSession {
    let reader: AVAssetReader
    let writer: AVAssetWriter
    let videoOutput: AVAssetReaderTrackOutput
    let videoInput: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    /// **Every sound track the daily is being written with.**
    ///
    /// Leg 0 is the camera's own audio, exactly as it always was. The rest are
    /// the sound recordist's files, matched to this take on timecode (owner:
    /// "чтоб он автоматически подружил нужные тейки и записывал в дейлик и
    /// дорожки с камеры и со звука"). A list rather than the old pair because
    /// a take is legitimately covered by more than one file — a per-take file
    /// and a running safety — and because one of them is not more the daily's
    /// sound than the other.
    let audio: [AudioLeg]

    /// One sound track: where its samples come from, where they go, and how
    /// far its clock is from the picture's.
    struct AudioLeg {
        /// nil for the camera's leg, which shares the item's own reader. A
        /// sound file brings its own, because it is a different asset with a
        /// different clock and its own `timeRange`.
        let reader: AVAssetReader?
        let output: AVAssetReaderOutput
        let input: AVAssetWriterInput
        /// Seconds into the SOUND at the picture's first frame — negative when
        /// the recordist rolled after the camera. Zero for the camera's leg,
        /// which is already on the picture's clock.
        let offsetIntoSound: Double
    }

    /// Open the whole rig against an already-reserved output URL (the caller
    /// holds the reservation so it can clean up whatever happens here).
    static func open(at url: URL, facts: DailiesSourceFacts,
                     codec: CaptureCodec = .h264,
                     bakedLook: String? = nil,
                     sounds: [SoundSync.Match] = []) throws
        -> DailiesSession {
        let reader: AVAssetReader
        let writer: AVAssetWriter
        do {
            reader = try AVAssetReader(asset: facts.asset)
            // The container follows the CODEC and is not a constant any more:
            // ProRes has no registered MPEG-4 sample entry, so the pair has to
            // move together or the run produces a file nothing opens.
            writer = try AVAssetWriter(outputURL: url,
                                       fileType: codec.dailiesContainer)
        } catch {
            throw DailiesAbort.failed(error.localizedDescription)
        }
        let (videoOutput, audioOutput) = try addOutputs(facts: facts,
                                                        to: reader)
        let (videoInput, adaptor) = try addVideoInput(facts: facts,
                                                      codec: codec, to: writer)
        var legs: [AudioLeg] = []
        if let audioOutput {
            legs.append(AudioLeg(reader: nil, output: audioOutput,
                                 input: addAudioInput(to: writer),
                                 offsetIntoSound: 0))
        }
        legs += soundLegs(for: sounds, in: writer)
        // **The source's own metadata, minus three keys that would be lies.**
        // Before `startWriting`, which is the only time a writer accepts it.
        // **What this run baked, stated by this run.** `com.takeshot.lut` is
        // the one key that is written rather than carried: it says a look is
        // already in the pixels, and the player refuses to apply one over it.
        // Copied from the source it would be a claim about the source; absent
        // from a proxy that really was graded, every player would grade it a
        // second time.
        //
        // **It rides in the QuickTime metadata key space, so an `.mp4` daily
        // cannot carry it** — measured, and the same limit the take's identity
        // runs into above. An H.264 proxy is baked all the same; what it
        // cannot do is TELL a player so, which means this app reviewing one as
        // Other content would show the viewing look over a look already in the
        // picture. A ProRes daily says it properly. Worth knowing before
        // anyone reads a clean `.mp4` and concludes the bake did not run.
        writer.metadata = Self.carriedMetadata(facts.metadata)
            + (bakedLook.map { [TakeWriter.lookItem(named: $0)] } ?? [])
        // moov up front: a daily gets dropped into review players and file
        // shares, where a streamable file starts playing before it finishes
        // copying.
        writer.shouldOptimizeForNetworkUse = true
        guard writer.startWriting() else {
            throw DailiesAbort.failed(failure(of: writer))
        }
        guard reader.startReading() else {
            writer.cancelWriting()
            throw DailiesAbort.failed(reader.error?.localizedDescription
                ?? "cannot read: \(facts.asset.url.lastPathComponent)")
        }
        return DailiesSession(reader: reader, writer: writer,
                              videoOutput: videoOutput,
                              videoInput: videoInput, adaptor: adaptor,
                              audio: legs)
    }

    /// The reader's two ends: video decoded to BGRA (so CoreGraphics can
    /// composite the strips directly), audio downmixed to the stereo pair.
    /// A take whose audio cannot be read still gets its picture — a silent
    /// daily beats no daily, and the failure modes there are exotic layouts,
    /// not footage problems.
    private static func addOutputs(facts: DailiesSourceFacts,
                                   to reader: AVAssetReader) throws
        -> (video: AVAssetReaderTrackOutput, audio: AVAssetReaderOutput?) {
        let video = AVAssetReaderTrackOutput(
            track: facts.videoTrack, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_32BGRA,
            ])
        guard reader.canAdd(video) else {
            throw DailiesAbort.failed(
                "cannot decode: \(facts.asset.url.lastPathComponent)")
        }
        reader.add(video)
        guard !facts.audioTracks.isEmpty else { return (video, nil) }
        let audio = AVAssetReaderAudioMixOutput(
            audioTracks: facts.audioTracks,
            audioSettings: DailiesEngine.audioReadSettings())
        guard reader.canAdd(audio) else { return (video, nil) }
        reader.add(audio)
        return (video, audio)
    }

    /// The writer's picture end: the chosen codec at the daily raster, fed
    /// through a pixel-buffer adaptor.
    ///
    /// **The writer is asked whether it can take the settings**, and that is
    /// the guard rather than the codec/container table alone: a mismatch there
    /// is otherwise discovered as a `startWriting` failure with a message
    /// nobody can act on, or — worse on some builds — as a file that writes
    /// and does not play. Asking costs nothing and the refusal names the
    /// combination.
    private static func addVideoInput(facts: DailiesSourceFacts,
                                      codec: CaptureCodec,
                                      to writer: AVAssetWriter) throws
        -> (input: AVAssetWriterInput,
            adaptor: AVAssetWriterInputPixelBufferAdaptor) {
        let settings = DailiesEngine.videoSettings(
            size: facts.outputSize, frameRate: facts.frameRate,
            colorimetry: facts.colorimetry, codec: codec)
        guard writer.canApply(outputSettings: settings, forMediaType: .video)
        else {
            throw DailiesAbort.failed(
                "\(codec.rawValue) cannot be written into "
                    + "\(codec.dailiesFileExtension.uppercased())")
        }
        let video = AVAssetWriterInput(mediaType: .video,
                                       outputSettings: settings)
        video.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: video, sourcePixelBufferAttributes: nil)
        writer.add(video)
        return (video, adaptor)
    }

    /// **One leg per matched sound file**, each with its own reader over its
    /// own asset.
    ///
    /// Stereo, and that is a decision with a cost worth stating: a poly WAV's
    /// channels are taken as AVFoundation hands them (the recordist's mix is
    /// what channels 1-2 of such a file are for), so a daily carries the
    /// recordist's SOUND rather than their individual microphones. Splitting a
    /// poly file into per-channel tracks means de-interleaving PCM by hand —
    /// AVFoundation's mix output downmixes and cannot select — and that is a
    /// feature of its own, not a line here.
    ///
    /// Capped, because every leg is another AAC encoder on a machine that may
    /// be capturing at the same time, and a run that quietly opened eleven of
    /// them would be discovering the limit rather than stating it. The report
    /// says what was left off.
    static let soundLegLimit = 4

    private static func soundLegs(for matches: [SoundSync.Match],
                                  in writer: AVAssetWriter) -> [AudioLeg] {
        matches.prefix(soundLegLimit).compactMap { match in
            let asset = AVURLAsset(url: match.sound.url)
            guard let reader = try? AVAssetReader(asset: asset) else { return nil }
            let tracks = asset.tracks(withMediaType: .audio)
            guard !tracks.isEmpty else { return nil }
            let output = AVAssetReaderAudioMixOutput(
                audioTracks: tracks,
                audioSettings: DailiesEngine.audioReadSettings())
            guard reader.canAdd(output) else { return nil }
            reader.add(output)
            // **Start the read where the picture does.** A recordist who
            // rolled ten seconds early has ten seconds this daily has no
            // picture for, and reading them would put the take's sound ten
            // seconds late under it.
            if match.offsetIntoSound > 0 {
                reader.timeRange = CMTimeRange(
                    start: CMTime(seconds: match.offsetIntoSound,
                                  preferredTimescale: 48_000),
                    duration: .positiveInfinity)
            }
            guard reader.startReading() else { return nil }
            let input = addAudioInput(to: writer)
            input.metadata = [trackNameItem(for: match.sound)]
            return AudioLeg(reader: reader, output: output, input: input,
                            offsetIntoSound: match.offsetIntoSound)
        }
    }

    /// What the track is CALLED, out of the file's own metadata (owner: "ну и
    /// дорожки чтоб были подписаны так как по метам").
    ///
    /// iXML's scene and take when the recordist wrote them, the file's own
    /// name otherwise — which is what a recordist names a file after anyway.
    /// A QuickTime track name, so it rides in a `.mov` daily and not in an
    /// `.mp4` one: the same measured container limit as every other key here.
    static func trackNameItem(for sound: BroadcastWaveFacts) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = .quickTimeUserDataTrackName
        let stem = sound.url.deletingPathExtension().lastPathComponent
        if let scene = sound.scene, let take = sound.take,
           !scene.isEmpty, !take.isEmpty {
            item.value = "\(stem) — \(scene)/\(take)" as NSString
        } else {
            item.value = stem as NSString
        }
        return item
    }

    /// The writer's sound end: AAC stereo, only when the reader has audio to
    /// feed it — an empty audio track helps nobody.
    private static func addAudioInput(to writer: AVAssetWriter)
        -> AVAssetWriterInput {
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: DailiesEngine.audioSettings())
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        return input
    }

    /// **What of the source's own metadata travels into the proxy.**
    ///
    /// Everything, minus three keys that would be untrue of the file being
    /// written — a copy is not the same thing as a carry-over:
    ///
    /// - `com.takeshot.origin` marks a file as one of THIS app's takes, and
    ///   the library scan adopts anything carrying it. A daily written into
    ///   the record folder would join the day's takes and be offered for
    ///   review, export and another round of dailies.
    /// - `com.takeshot.levels` says the codes are studio swing and need
    ///   expanding on playback. The proxy's codes have already been expanded,
    ///   by `StudioSwing.map` on the way in — copying the key would have every
    ///   player expand them a second time, which is exactly the double
    ///   expansion that key exists to prevent.
    /// - `com.takeshot.lut` says a look is already baked into the pixels, and
    ///   the player refuses to apply one over it. It has to state what THIS
    ///   run did, so it is written by the run rather than copied.
    ///
    /// Everything else is the take's identity and the camera's own facts —
    /// roll, clip, scene/shot/take, the frame rate, both description atoms,
    /// make/model/creation date — and all of it is what an assistant looks for
    /// when a proxy is the only file in front of them.
    ///
    /// **The container decides how much of it arrives, and the writer sorts
    /// that out itself — measured, not assumed.** A ProRes daily is a `.mov`
    /// and keeps all of it, QuickTime metadata and user data alike. An
    /// H.264/HEVC daily is an `.mp4`, which has no QuickTime metadata atom at
    /// all: every reverse-DNS key is dropped and what survives is the
    /// description, mapped to ISO user data (`uiso/dscp`) — the scene, shot
    /// and take as a sentence, which is why a take is written with a pair of
    /// description atoms in the first place. Nothing here filters by key
    /// space: handed items it cannot store, the writer drops them and writes
    /// the file (`theProxysMetadataFollowsItsContainer`), and a filter
    /// guessing at the same rule would only be a second, worse copy of it.
    static func carriedMetadata(_ source: [AVMetadataItem]) -> [AVMetadataItem] {
        let dropped: Set<String> = [TakeWriter.markerKey, TakeWriter.levelsKey,
                                    TakeWriter.lutKey]
        return source.filter { item in
            if let key = item.key as? String, dropped.contains(key) {
                return false
            }
            return true
        }
    }

    static func failure(of writer: AVAssetWriter) -> String {
        writer.error?.localizedDescription
            ?? "writer failed (status \(writer.status.rawValue))"
    }
}

extension CaptureCodec {
    /// The `AVFileType` a daily in this codec is written into — the
    /// AVFoundation half of `dailiesFileExtension`, kept beside the writer
    /// that uses it and derived from the same question so the extension on
    /// disk and the container inside it cannot disagree.
    var dailiesContainer: AVFileType {
        dailiesFileExtension == "mp4" ? .mp4 : .mov
    }
}
