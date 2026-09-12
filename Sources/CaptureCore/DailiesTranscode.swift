@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
@preconcurrency import CoreVideo
import Foundation

/// One item of the dailies queue: read the take, composite the burn-ins,
/// write the .mp4. A class so the steps can be small methods over shared
/// state (the same shape as `OffloadRun`); one instance = one item.
///
/// The pieces it drives each live with their own rules: the probe and the
/// reader/writer rig in `DailiesSession`, the per-frame compositing in
/// `DailiesFrameComposer`.
final class DailiesTranscode {
    private let item: DailiesItem
    private let index: Int
    private let count: Int
    private let burnins: DailiesBurnins
    private let folder: URL
    private let codec: CaptureCodec
    /// The look to bake, or nil for a clean proxy — see `DailiesLook`.
    private let look: DailiesLook?
    /// The anamorphic squeeze to take out of the picture; 1 leaves it alone.
    private let desqueeze: Double
    /// The ceiling the daily's raster is fitted into.
    private let resolution: DailiesResolution
    /// Every sound file the run was given; this item takes the ones whose
    /// timecode overlaps its own (`SoundSync`).
    private let sounds: [BroadcastWaveFacts]
    private let control: DailiesControl
    private let publish: @Sendable (DailiesProgress) -> Void

    private var session: DailiesSession?
    private var outputURL: URL?
    private var framesDone = 0
    /// Internal for `+Timecode`, which places the last span at the end of
    /// the picture and learns where that is from the probe.
    var framesTotal = 0
    private var lastPublished = Date.distantPast
    private var lastPausedState = false
    /// Audio sample read but not yet written (its turn on the timeline has
    /// not come) — the interleave's one-sample lookahead.
    /// One held sample per audio leg — the camera's, and one per matched
    /// sound file. Held here rather than on the session because a leg is a
    /// value and this is the pump's own state.
    private var pendingAudio: [CMSampleBuffer?] = []
    /// What to add to each leg's timestamps to put them on the daily's
    /// timeline. Known only once the first picture frame has arrived, because
    /// that is what the writer's session starts at.
    private var audioShift: [CMTime] = []
    /// Legs already marked finished, so the end does not mark them twice — a
    /// second `markAsFinished` is a writer error, not a no-op.
    private var finishedAudio: Set<Int> = []
    /// Internal rather than private, these two: the timecode track's writer
    /// moved into `+Timecode` when this type reached its length ceiling, and
    /// a frame's duration and "has the track been closed" are the only state
    /// it needs from here.
    var frameDuration = CMTime(value: 1, timescale: 25)
    /// The timecode track has had its samples and been closed — see
    /// `writeTimecode`, which does both at the FIRST frame.
    var timecodeWritten = false
    /// The same for the chapter track, for the same reason and by the same
    /// rule — see `writeChapters`.
    var chaptersWritten = false

    /// How far AHEAD of the picture the sound is kept.
    ///
    /// `AVAssetWriter` holds an input back while another lags, and audio fed
    /// only up to the current frame is by definition never ahead: the writer
    /// stops granting video, the loop stops asking for audio, and the run
    /// stops — measured as a 2-second take with sound that never finished
    /// while a 1-second one did, because a second is about what the writer
    /// buffers before it starts holding back.
    static let audioLead = CMTime(seconds: 1, preferredTimescale: 600)

    init(item: DailiesItem, index: Int, count: Int, burnins: DailiesBurnins,
         folder: URL, codec: CaptureCodec = .h264, look: DailiesLook? = nil,
         desqueeze: Double = 1, resolution: DailiesResolution = .hd,
         sounds: [BroadcastWaveFacts] = [],
         control: DailiesControl,
         publish: @escaping @Sendable (DailiesProgress) -> Void) {
        self.item = item
        self.index = index
        self.count = count
        self.burnins = burnins
        self.folder = folder
        self.codec = codec
        self.look = look
        self.desqueeze = desqueeze
        self.resolution = resolution
        self.sounds = sounds
        self.control = control
        self.publish = publish
    }

    func run() async -> DailiesItemResult {
        do {
            let url = try await transcode()
            // The file exists now; the filesystem is the authority from here.
            outputURL.map(CapturePipeline.releaseReservation(for:))
            publishProgress(force: true)
            return DailiesItemResult(source: item.source, output: url)
        } catch let abort as DailiesAbort {
            cleanUpPartialOutput()
            switch abort {
            case .cancelled:
                return DailiesItemResult(source: item.source, wasCancelled: true)
            case .failed(let reason):
                return DailiesItemResult(source: item.source, failure: reason)
            }
        } catch {
            cleanUpPartialOutput()
            return DailiesItemResult(source: item.source,
                                     failure: error.localizedDescription)
        }
    }

    // MARK: - the transcode

    private func transcode() async throws -> URL {
        let facts = try await DailiesSourceFacts.probe(item: item,
                                                       burnins: burnins,
                                                       desqueeze: desqueeze,
                                                       resolution: resolution)
        framesTotal = facts.framesTotal
        frameDuration = TakeWriter.frameDuration(at: facts.frameRate)
        // Claimed through the same process-wide reservation every writing
        // path uses, so a daily can never land on a name a take (or another
        // daily) is about to take. Collisions get the app's `_2` suffix.
        let url = CapturePipeline.uniqueURL(
            for: folder.appendingPathComponent(item.outputName)
                .appendingPathExtension(codec.dailiesFileExtension))
        outputURL = url
        // The look's NAME goes on the file only when this run really baked
        // one: `DailiesFrameComposer` declines over a source that already
        // carries a look, and a proxy claiming a grade it does not have is
        // worse than one claiming nothing.
        let baked = facts.bakedLook == nil ? look?.name : nil
        let matched = SoundSync.matches(
            pictureStart: DailiesEngine.startSecondsSinceMidnight(
                of: item, frameRate: facts.frameRate),
            pictureDuration: Double(facts.framesTotal) / max(1, facts.frameRate),
            in: sounds)
        let session = try await DailiesSession.open(
            at: url, facts: facts, codec: codec, bakedLook: baked,
            sounds: matched)
        self.session = session
        publishProgress(force: true)
        try await pump(session, composer: try DailiesFrameComposer(
            item: item, burnins: burnins, facts: facts, look: look?.cube,
            lookIntensity: look?.intensity ?? 1))
        try await finish(session)
        return url
    }

    // MARK: - the frame loop

    private func pump(_ session: DailiesSession,
                      composer: DailiesFrameComposer) async throws {
        var sessionStarted = false
        while let sample = session.videoOutput.copyNextSampleBuffer() {
            // The gate sits between frames: pause holds HERE (recording
            // protection), and cancel/skip leave the loop with a whole frame,
            // never half of one.
            try await gate()
            guard let source = CMSampleBufferGetImageBuffer(sample) else {
                continue
            }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            if !sessionStarted {
                session.writer.startSession(atSourceTime: pts)
                sessionStarted = true
                startAudio(session: session, at: pts)
                writeTimecode(session, from: pts)
                writeChapters(session, from: pts)
            }
            // **Sound first, then the picture.** With one audio input the
            // order did not matter; with several it is the whole difference
            // between a run and a deadlock. `AVAssetWriter` holds an input
            // back while another one lags, so appending a frame before the
            // legs have been fed to the same moment parks the video input on
            // a leg that is waiting for its turn — measured, as a run that
            // never produced a first frame.
            try await pumpAudio(upTo: pts + Self.audioLead, session: session)
            try await append(try composer.compose(source, pts: pts),
                             at: pts, session: session)
            framesDone += 1

            publishProgress(force: false)
            await Task.yield()
        }
        if session.reader.status == .failed {
            throw DailiesAbort.failed(session.reader.error?.localizedDescription
                ?? "read failed: \(item.source.lastPathComponent)")
        }
        guard sessionStarted else {
            throw DailiesAbort.failed(
                "no video frames: \(item.source.lastPathComponent)")
        }
        try await pumpAudio(upTo: .positiveInfinity, session: session)
    }

    private func finish(_ session: DailiesSession) async throws {
        session.videoInput.markAsFinished()
        // Only when the first frame never came: `writeTimecode` closes the
        // track itself, and a second `markAsFinished` is a writer error.
        if !timecodeWritten { session.timecode?.input.markAsFinished() }
        if !chaptersWritten { session.chapters?.input.markAsFinished() }
        for (index, leg) in session.audio.enumerated()
        where !finishedAudio.contains(index) {
            leg.input.markAsFinished()
        }
        await session.writer.finishWriting()
        guard session.writer.status == .completed else {
            throw DailiesAbort.failed(DailiesSession.failure(of: session.writer))
        }
    }

    /// Pause/cancel checkpoint. Pause is a suspension loop, not a parked
    /// thread; each transition in or out publishes once so the UI can say
    /// "paused — recording" the moment it happens.
    private func gate() async throws {
        try checkCancelled()
        guard control.isPaused else {
            notePauseState(false)
            return
        }
        notePauseState(true)
        while control.isPaused {
            try checkCancelled()
            try? await Task.sleep(for: .milliseconds(100))
        }
        notePauseState(false)
    }

    private func checkCancelled() throws {
        if control.isCancelled || control.isSkipped(item: index) {
            throw DailiesAbort.cancelled
        }
    }

    private func notePauseState(_ paused: Bool) {
        guard paused != lastPausedState else { return }
        lastPausedState = paused
        publishProgress(force: true)
    }

    // MARK: - feeding the writer

    private func append(_ buffer: CVPixelBuffer, at pts: CMTime,
                        session: DailiesSession) async throws {
        // Offline encode back-pressure: wait it out rather than drop — every
        // frame of a daily exists on disk already, unlike a live capture.
        //
        // **And the wait reads the stop flag.** These two back-pressure loops
        // were the only places in the engine that did not: everywhere else the
        // cancel is checked at the top of the frame loop and between items, so
        // a batch stops within a frame. Here, an input that stops asking for
        // data — the classic multi-input `AVAssetWriter` stall — parks the run
        // in a two-millisecond sleep for ever, with the panel already saying
        // "stopping…" and nothing ever ending (owner: "попытка остановить
        // дейлисы в ui так и не стопнула их").
        while !session.videoInput.isReadyForMoreMediaData {
            try checkCancelled()
            guard session.writer.status == .writing else {
                throw DailiesAbort.failed(DailiesSession.failure(of: session.writer))
            }
            // **The sleep propagates cancellation**, which `try?` used to
            // swallow. It matters because the failure this loop guards is a
            // HANG: a writer that stops granting an input parks the run, and
            // a task nobody can cancel parks whatever is waiting on it — a
            // test's time limit included, which is what made the stall below
            // invisible to the suite for as long as it existed.
            try await Task.sleep(for: .milliseconds(2))
        }
        guard session.adaptor.append(buffer, withPresentationTime: pts) else {
            throw DailiesAbort.failed(DailiesSession.failure(of: session.writer))
        }
    }

    /// **Where each leg's clock lands on the daily's**, known only now.
    ///
    /// The writer's session starts at the first picture frame's own timestamp,
    /// so that is what a sound sample has to be measured against. A sample at
    /// `t` seconds into a sound FILE is the picture at `t - offsetIntoSound`
    /// seconds in, so it belongs at `firstPTS + (t - offsetIntoSound)` — one
    /// constant per leg.
    ///
    /// The camera's leg gets zero: its samples come off the same asset as the
    /// picture and are already on that clock. Shifting them would move the
    /// take's own sound by the length of its own head.
    private func startAudio(session: DailiesSession, at firstPTS: CMTime) {
        pendingAudio = Array(repeating: nil, count: session.audio.count)
        audioShift = session.audio.map { leg in
            guard leg.reader != nil else { return .zero }
            return firstPTS - CMTime(seconds: leg.offsetIntoSound,
                                     preferredTimescale: 48_000)
        }
    }

    /// Every audio leg, pumped up to the picture's current time.
    ///
    /// One loop per leg rather than one shared loop, because the legs are
    /// different assets with different clocks: the camera's samples are
    /// already on the daily's timeline and a sound file's are on the
    /// recordist's, shifted onto it by `audioShift`.
    private func pumpAudio(upTo limit: CMTime,
                           session: DailiesSession) async throws {
        for (index, leg) in session.audio.enumerated() {
            try await pump(leg: leg, at: index, upTo: limit, session: session)
        }
    }

    private func pump(leg: DailiesSession.AudioLeg, at index: Int,
                      upTo limit: CMTime,
                      session: DailiesSession) async throws {
        guard index < pendingAudio.count else { return }
        let shift = index < audioShift.count ? audioShift[index] : .zero
        while true {
            if pendingAudio[index] == nil {
                pendingAudio[index] = leg.output.copyNextSampleBuffer()
            }
            guard let sample = pendingAudio[index] else {
                // **An exhausted leg is finished HERE, not at the end.** A
                // writer waits for every input it was given, so a leg that has
                // run out and says nothing holds the picture back for the rest
                // of the take — the multi-input stall, from the other side.
                // Marking it the moment it runs dry lets the rest of the run
                // proceed; `finish` marks whatever is left.
                if !finishedAudio.contains(index) {
                    finishedAudio.insert(index)
                    leg.input.markAsFinished()
                }
                return
            }
            let stamped = Self.shifted(sample, by: shift) ?? sample
            guard CMSampleBufferGetPresentationTimeStamp(stamped) <= limit
            else { return }
            while !leg.input.isReadyForMoreMediaData {
                try checkCancelled() // see `append` above
                guard session.writer.status == .writing else {
                    throw DailiesAbort.failed(
                        DailiesSession.failure(of: session.writer))
                }
                try await Task.sleep(for: .milliseconds(2)) // see `append`
            }
            leg.input.append(stamped)
            pendingAudio[index] = nil
        }
    }

    // MARK: - progress and cleanup

    private func publishProgress(force: Bool) {
        // Five snapshots a second is smooth and free; every forced publish is
        // a moment the numbers people watch actually change (item start/end,
        // pause transitions) — the offload's rule.
        let now = Date()
        guard force || now.timeIntervalSince(lastPublished) >= 0.2 else {
            return
        }
        lastPublished = now
        publish(DailiesProgress(
            itemIndex: index, itemCount: count,
            currentFile: item.source.lastPathComponent,
            framesDone: framesDone, framesTotal: framesTotal,
            isPaused: control.isPaused, isCancelling: control.isCancelled))
    }

    /// A stopped or failed item leaves nothing behind: a half-written daily
    /// that plays until it stops is worse than no daily.
    private func cleanUpPartialOutput() {
        session?.reader.cancelReading()
        session?.writer.cancelWriting()
        guard let outputURL else { return }
        try? FileManager.default.removeItem(at: outputURL)
        CapturePipeline.releaseReservation(for: outputURL)
    }
}
