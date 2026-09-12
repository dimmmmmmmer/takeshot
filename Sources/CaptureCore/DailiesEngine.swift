@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
@preconcurrency import CoreVideo
import Foundation

/// Editorial/review dailies from finished takes: each ProRes .mov is
/// transcoded to a small H.264 .mp4 with the burn-ins composited per frame.
///
/// The shape of the queue, which is the contract the UI and the tests hold it
/// to:
///
/// - **FIFO, one at a time.** Dailies are a background courtesy; two encodes
///   at once would just split the machine the next take needs.
/// - **A failed item is marked and skipped.** One unreadable take must never
///   cost the other thirty their dailies.
/// - **Recording wins, always.** While the app records, the queue holds
///   between frames (`DailiesControl.setPaused`) and resumes when the take
///   ends — a daily must never compete with `TakeWriter` for the disk or the
///   encoder. The sources are finished files; recordings are never touched.
/// - **Cancel is safe.** Stop deletes the partial output — a half-written
///   daily that plays until it stops is worse than no daily.
///
/// `async` rather than a blocking queue like `OffloadEngine`: the media setup
/// is AVFoundation's async loading, and the pause gate is a suspension, not a
/// parked thread. The app runs it in a utility-priority task.
public enum DailiesEngine {
    /// Longest edge of a daily. Sources above 1080p are downscaled to fit;
    /// smaller sources keep their size (upscaling buys nothing).
    static let maxSize = CGSize(width: 1920, height: 1080)
    /// H.264 rate at full 1080p, scaled by area for other sizes: enough for
    /// review and small enough to mail.
    static let bitsPerSecondAt1080p = 10_000_000

    /// Run the queue to completion (or to Stop) and report every item.
    ///
    /// `codec` defaults to H.264, which is what every daily this app has ever
    /// written was — so a caller that does not care is unchanged.
    /// `alsoInto` gets a COPY of each finished daily.
    ///
    /// Copied and not encoded again: a second encode would double the cost of
    /// the whole batch to produce a byte-identical file, and this runs on a
    /// machine shared with a capture path that must not be made to wait. A
    /// copy that fails does not fail the item — the daily exists, and the
    /// report says which shelf it did not reach.
    public static func run(
        items: [DailiesItem], burnins: DailiesBurnins, into folder: URL,
        alsoInto extras: [URL] = [], codec: CaptureCodec = .h264,
        look: DailiesLook? = nil, desqueeze: Double = 1,
        resolution: DailiesResolution = .hd,
        normalizeAudio: Bool = false,
        syncWith takes: [TakeSync.Candidate] = [],
        sounds: [BroadcastWaveFacts] = [],
        waveformSync: Bool = false,
        circledOnly: Bool = false,
        skipFinished: Bool = false,
        control: DailiesControl = DailiesControl(),
        progress: @escaping @Sendable (DailiesProgress) -> Void = { _ in })
        async -> DailiesReport {
        if let refusal = openDestination(folder, for: items) { return refusal }
        // **The folder's own note about itself.** Read once, written after
        // every item: a run that is killed mid-day leaves the dailies it
        // finished AND the record of them, so the next one starts where this
        // one stopped instead of re-rendering the morning (`DailiesJournal`).
        var journal = DailiesProgressJournal.read(in: folder)
        // **Which take each clip IS, settled before the loop** (owner: "чтоб
        // пользователь отметил галку допустим «синковать информацию с
        // тейками», чтоб у нас ин/аут сработал таким образом").
        //
        // Before, and not inside the transcode, because the trim is part of an
        // item's RECIPE: the skip decision and the note written after it both
        // have to be about the item as it will actually be rendered. Matching
        // inside would mean asking the journal about an item nobody renders —
        // and the answer would be to re-render every synced daily, for ever.
        let items = await resolve(items, syncWith: takes)
        // **The rolls timecode cannot place**, read once for the whole run —
        // see `DailiesEngine+Waveform`. Nothing at all when the run was not
        // asked to listen, which is every run by default.
        let byEar = await waveformCandidates(sounds, enabled: waveformSync)
        let destination = Destination(
            folder: folder,
            recipe: DailiesRecipe.fingerprint(burnins: burnins, codec: codec,
                                              look: look, desqueeze: desqueeze,
                                              resolution: resolution,
                                              normalizeAudio: normalizeAudio))
        var results: [DailiesItemResult] = []
        for (index, item) in items.enumerated() {
            guard !control.isCancelled else {
                // Everything not reached is cancelled, not silently absent —
                // the report's length always matches the queue's.
                results.append(contentsOf: items[index...].map {
                    DailiesItemResult(source: $0.source, wasCancelled: true)
                })
                break
            }
            if circledOnly, item.rating != .good {
                results.append(filtered(item, at: (index, items.count),
                                        progress: progress))
                continue
            }
            if skipFinished,
               let done = skipped(item, at: (index, items.count),
                                  journal: journal, into: destination,
                                  progress: progress) {
                results.append(done)
                continue
            }
            let transcode = DailiesTranscode(
                item: item, index: index, count: items.count,
                burnins: burnins, folder: folder, codec: codec, look: look,
                desqueeze: desqueeze, resolution: resolution,
                normalizeAudio: normalizeAudio, sounds: sounds,
                byEar: byEar, control: control, publish: progress)
            var result = await transcode.run()
            if let output = result.output, !extras.isEmpty {
                result.copyFailures = copy(output, into: extras)
            }
            await note(result, of: item, into: destination, journal: &journal)
            results.append(result)
        }
        // Cancel only counts if it cut the run short (the offload's rule):
        // Stop pressed as the last frame lands still means every daily exists.
        let stoppedShort = results.contains { $0.wasCancelled }
        return DailiesReport(items: results,
                             wasCancelled: control.isCancelled && stoppedShort)
    }

    /// **The item this folder already holds**, or nil to render it.
    ///
    /// A skip is still an item in the report and still a tick on the progress
    /// bar: a queue that jumps from 3 to 40 with no rows in between reads as
    /// a queue that lost thirty-seven takes.
    /// **Where a run is writing and by what recipe** — the pair every journal
    /// question needs, carried as one value so neither helper grows a
    /// parameter list nobody can read.
    struct Destination {
        let folder: URL
        let recipe: String

        /// **The recipe of one ITEM**: the run's, plus whatever that item
        /// carries that changes the file it produces.
        ///
        /// Only the trim so far, and it has to be per item rather than per
        /// run: every take has its own marks, and a recipe that could not say
        /// so would skip a take whose in point had moved since the last pass.
        /// An untrimmed item adds nothing, so every fingerprint ever written
        /// is unchanged.
        func recipe(for item: DailiesItem) -> String {
            recipe + DailiesTrim.recipePart(item.range)
        }
    }

    private static func skipped(
        _ item: DailiesItem, at place: (index: Int, count: Int),
        journal: DailiesJournal, into destination: Destination,
        progress: @Sendable (DailiesProgress) -> Void) -> DailiesItemResult? {
        guard let existing = journal.finished(source: item.source,
                                              recipe: destination.recipe(for: item),
                                              named: item.outputName,
                                              in: destination.folder)
        else { return nil }
        progress(DailiesProgress(
            itemIndex: place.index, itemCount: place.count,
            currentFile: item.source.lastPathComponent,
            framesDone: 1, framesTotal: 1, isPaused: false,
            isCancelling: false))
        return DailiesItemResult(source: item.source, output: existing,
                                 wasSkipped: true)
    }

    /// **The note, after the item and not at the end of the run** — see
    /// `DailiesJournal` for why that is the whole point of it.
    ///
    /// A note that cannot be written costs this run nothing: the daily exists
    /// either way, and the next run re-renders it rather than skipping
    /// something it has no record of.
    private static func note(_ result: DailiesItemResult, of item: DailiesItem,
                             into destination: Destination,
                             journal: inout DailiesJournal) async {
        guard let output = result.output, !result.wasSkipped,
              let source = DailiesJournal.facts(of: item.source),
              let made = DailiesJournal.facts(of: output) else { return }
        // **Read back off the FILE**, not computed from the frames that went
        // in: what the verify pass will measure later is the file, so what it
        // is measured against has to be the file as it was written. One asset
        // open against a transcode that took seconds.
        let asset = AVURLAsset(url: output)
        let seconds = (try? await asset.load(.duration).seconds)
            .flatMap { $0.isFinite ? $0 : nil }
        let audio = (try? await asset.tracks(ofType: .audio))?.count
        journal.record(DailiesJournal.Entry(
            source: item.source.lastPathComponent,
            sourceSize: source.size, sourceModified: source.modified,
            recipe: destination.recipe(for: item),
            output: output.lastPathComponent,
            outputSize: made.size, outputName: item.outputName,
            outputSeconds: seconds, outputAudio: audio,
            finishedAt: Date()))
        _ = try? DailiesProgressJournal.write(journal, into: destination.folder)
    }

    /// Put a finished daily on every other shelf, and say which ones refused.
    ///
    /// Best-effort per destination: a disk that is full or gone costs that
    /// copy and nothing else. The daily itself already exists, and an item
    /// failed over a second shelf would be a report that says the footage has
    /// no daily when it has one.
    static func copy(_ file: URL, into folders: [URL]) -> [String] {
        var failures: [String] = []
        for folder in folders {
            do {
                try FileManager.default.createDirectory(
                    at: folder, withIntermediateDirectories: true)
                let target = CapturePipeline.uniqueURL(
                    for: folder.appendingPathComponent(file.lastPathComponent))
                try FileManager.default.copyItem(at: file, to: target)
                CapturePipeline.releaseReservation(for: target)
            } catch {
                failures.append("\(folder.lastPathComponent): "
                    + error.localizedDescription)
            }
        }
        return failures
    }

    // MARK: - the encode parameters (pure, unit-tested)

    /// Output raster: fit into 1080p preserving aspect, never upscale, and
    /// keep dimensions even — H.264 4:2:0 subsampling needs them, and an odd
    /// edge makes some encoders refuse the session outright.
    /// The proxy's raster, with an anamorphic squeeze taken OUT of it when the
    /// operator asked for that (owner: "и думаю еще можно настройку сделать
    /// чтоб десквиз запекать").
    ///
    /// Width times the factor, height untouched — the one convention the whole
    /// app uses for a desqueeze (`MetalPreviewLayer+Render`, `displayAspect`).
    /// Folding it in HERE rather than adding a stage is what makes the rest
    /// free: the composer already resamples whenever the source and the output
    /// differ, and the burn-in overlay is built at the output size, so the
    /// strips are laid out on the final raster and are never stretched with
    /// the picture.
    ///
    /// It also takes the `pasp` off the file by construction, which is right:
    /// `TakeWriter.pixelAspect` answers for the two SD rasters and a
    /// desqueezed one is not either of them, so a baked proxy states square
    /// pixels — which is what it now has.
    public static func outputSize(for natural: CGSize, desqueeze: Double,
                                  resolution: DailiesResolution = .hd) -> CGSize {
        guard desqueeze > 0, desqueeze != 1 else {
            return outputSize(for: natural, resolution: resolution)
        }
        return outputSize(for: CGSize(width: natural.width * desqueeze,
                                      height: natural.height),
                          resolution: resolution)
    }

    /// The daily's raster: the source's own shape, fitted inside the chosen
    /// ceiling and never scaled up.
    ///
    /// A raster this cannot read at all falls back to the CEILING rather than
    /// to nothing — a zero-sized output is a run that fails at the encoder,
    /// and a 1080p frame of a clip whose natural size the container would not
    /// state is a daily somebody can look at.
    public static func outputSize(for natural: CGSize,
                                  resolution: DailiesResolution = .hd) -> CGSize {
        let width = abs(natural.width)
        let height = abs(natural.height)
        guard let limit = resolution.limit else {
            guard width > 0, height > 0 else { return maxSize }
            return CGSize(width: even(width), height: even(height))
        }
        guard width > 0, height > 0 else { return limit }
        let scale = min(1, min(limit.width / width, limit.height / height))
        return CGSize(width: even(width * scale), height: even(height * scale))
    }

    private static func even(_ value: CGFloat) -> CGFloat {
        max(2, CGFloat(Int(value / 2) * 2))
    }

    /// H.264 settings for the daily: bitrate scaled by area from the 1080p
    /// anchor so a downscaled or small-raster source is not drowned in bits.
    ///
    /// `colorimetry` is the SOURCE's, and it decides one thing: whether the
    /// proxy has to state what its codes are. An SDR source gets no colour
    /// properties key at all — which is a different thing from getting the
    /// Rec.709 one, and it is what makes "an SDR daily is byte for byte the
    /// file it was before any of this" true of one branch rather than of a
    /// diff. An HDR source has been tone mapped into a Rec.709 curve by the
    /// time it reaches the encoder, so the file must say Rec.709 or every
    /// player puts a PQ or HLG EOTF over codes that already went through one
    /// and crushes the picture a second time.
    ///
    /// The PRIMARIES are the deliberate half. They are NOT converted and the
    /// proxy says Rec.2020, because that is literally what its codes are: the
    /// tone map is per channel and cannot move a primary, so the picture that
    /// comes out of it is Rec.2020 primaries under a Rec.709 curve — the exact
    /// combination `ColorTags.rec2020Preset` exists for and the exact one the
    /// live display buffer already carries. Converting the gamut instead would
    /// mean a 3x3 matrix in linear light per pixel, in 8 bits, written from
    /// scratch, to reach a result a colour-managed player computes exactly and
    /// for free from the tag.
    static func videoSettings(size: CGSize, frameRate: Double,
                              colorimetry: WireColorimetry = .sdr,
                              codec: CaptureCodec = .h264)
        -> [String: Any] {
        let areaFraction = size.width * size.height
            / (maxSize.width * maxSize.height)
        let bitrate = max(1_000_000,
                          Int(Double(bitsPerSecondAt1080p) * areaFraction))
        var settings: [String: Any] = [
            AVVideoCodecKey: codec.avCodecType,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ]
        // **ProRes is not given a bitrate, and that is not an omission.** Its
        // rate is a property of the picture and the flavour — the encoder is
        // told what to preserve, not how many bits to spend — and a bitrate
        // key handed to it is either ignored or refused depending on the
        // build. `needsBitrate` is the same question `TakeWriter` asks of the
        // same enum for the same reason.
        if codec.needsBitrate {
            settings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey:
                    Int(max(1, frameRate.rounded())),
            ]
        }
        // **Always, not only for an HDR source** (owner: "ток теги 1-1-1
        // полюбас должны быть").
        //
        // Left unwritten, the file took its colour from whatever the decoded
        // buffer happened to carry — the source's own tags for a frame handed
        // straight through, and NOTHING for the same footage over 1080p,
        // because a scaled frame comes out of a pool that carries no colour
        // attachments. So one take could produce a proxy tagged 709, the same
        // take in UHD one tagged with nothing at all, and a 601 or Rec.2020
        // SDR source one tagged with a gamut its codes are no longer on. A
        // file that does not state its colour is a file every tool guesses
        // about differently.
        //
        // What it states is `proxyPreset` — 1-1-1, for every source there is.
        settings[AVVideoColorPropertiesKey] = ColorTags
            .videoColorProperties(for: proxyPreset)
        // The sampling aspect, when the raster has one. Reused from the take
        // writer rather than restated: only the two SD rasters carry one, and
        // SD is never scaled (`outputSize`), so the source's own aspect is
        // still the proxy's. Without it a 720×576 daily claims square pixels
        // and every player draws it 1.25:1 wrong.
        if let aspect = TakeWriter.pixelAspect(width: Int(size.width),
                                               height: Int(size.height)) {
            settings[AVVideoPixelAspectRatioKey] = [
                AVVideoPixelAspectRatioHorizontalSpacingKey: aspect.horizontal,
                AVVideoPixelAspectRatioVerticalSpacingKey: aspect.vertical,
            ]
        }
        return settings
    }

    /// **What a daily says about its colour: Rec.709, always** (owner: "ток
    /// теги 1-1-1 полюбас должны быть").
    ///
    /// True rather than merely declared. It used to be `displayPreset`, which
    /// answers 2020 for a wide-gamut source because that is what the codes
    /// were: a tone map moves the curve and cannot move a primary, and saying
    /// 709 over Rec.2020 codes is the mis-declaration that put a desaturated
    /// picture next to a correct one on the cart once already. The proxy is
    /// CONVERTED into Rec.709 now — `CubeLUT.gamut`, on the composer's cube
    /// stage — so the honest answer and the wanted one are the same answer.
    ///
    /// One expression, read by the encode settings here and by the tag on
    /// every buffer handed to the writer (`DailiesFrameComposer.compose`): a
    /// buffer tagged differently from the settings is the mismatch
    /// VideoToolbox colour-converts on.
    public static let proxyPreset: String? = nil

    /// **When a take started, in seconds since midnight** — the picture's half
    /// of the sound match.
    ///
    /// From the take's own start timecode at its REAL rate, never the nominal
    /// one: a drop-frame camera delivers `fps × 1000/1001` frames a second, so
    /// dividing a 29.97 clock by 30 is 3.6 seconds of error an hour — which is
    /// several takes' worth of sound landing under the wrong picture. The rule
    /// is `TakeLogExporter`'s, which solved it for markers first.
    ///
    /// A clip with no timecode answers 0, and the caller's overlap rule then
    /// matches it against sound recorded in the first minutes of the day —
    /// which is why a take with no timecode is reported as UNMATCHABLE rather
    /// than silently matched.
    public static func startSecondsSinceMidnight(of item: DailiesItem,
                                                 frameRate: Double) -> Double {
        guard let timecode = item.startTimecode else { return 0 }
        let rate = frameRate > 0 ? frameRate : Double(max(1, timecode.fps))
        return Double(timecode.frameNumber) / rate
    }

    /// AAC stereo for every daily, whatever the take recorded: editorial
    /// players choke on 16 discrete channels, and the reader downmixes the
    /// embed to the pair on the way past.
    static func audioSettings() -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000,
        ]
    }

    /// What the reader decodes the take's PCM into: the writer's AAC input.
    static func audioReadSettings() -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    /// The timecode the burn-in runs on: every anchor of the file's timecode
    /// track (a mid-take Rec Run re-anchor stays frame-accurate), else the
    /// take's remembered start TC, else a zero clock — a daily with a running
    /// counter beats one with an empty strip.
    static func timeline(for asset: AVAsset, item: DailiesItem,
                         frameRate: Double) async -> DailiesTimeline {
        timeline(anchors: await TimecodeReader.timelineAnchors(of: asset),
                 item: item, frameRate: frameRate)
    }

    /// The same, from anchors already read. The probe reads them ONCE and
    /// builds two things out of them — this clock for the strip, and the
    /// proxy's own timecode track — and reading the file twice is how those
    /// two would come to disagree about a take.
    static func timeline(anchors: [DailiesTimeline.Anchor], item: DailiesItem,
                         frameRate: Double) -> DailiesTimeline {
        if !anchors.isEmpty {
            return DailiesTimeline(anchors: anchors, frameRate: frameRate)
        }
        let start = item.startTimecode ?? Timecode(
            frameNumber: 0, fps: Int(max(1, frameRate.rounded())))
        return DailiesTimeline(
            anchors: [DailiesTimeline.Anchor(seconds: 0, timecode: start)],
            frameRate: frameRate)
    }

    /// **What goes into the PROXY's timecode track**, which is not the same
    /// question as what the strip counts.
    ///
    /// The strip falls back to a zero clock when the file says nothing,
    /// because a daily with a running counter beats one with an empty strip.
    /// A TRACK cannot do that: an NLE reads a timecode track as the take's
    /// identity in time, and a file claiming 00:00:00:00 would conform
    /// alongside every other untimecoded proxy at the same place on the
    /// timeline. Empty here means the proxy gets no track at all, which is
    /// exactly what its source has.
    static func timecodeTrack(anchors: [DailiesTimeline.Anchor],
                              item: DailiesItem) -> [DailiesTimeline.Anchor] {
        if !anchors.isEmpty { return anchors }
        guard let start = item.startTimecode else { return [] }
        return [DailiesTimeline.Anchor(seconds: 0, timecode: start)]
    }
}
