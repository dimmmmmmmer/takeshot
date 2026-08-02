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
    private let control: DailiesControl
    private let publish: @Sendable (DailiesProgress) -> Void

    private var session: DailiesSession?
    private var outputURL: URL?
    private var framesDone = 0
    private var framesTotal = 0
    private var lastPublished = Date.distantPast
    private var lastPausedState = false
    /// Audio sample read but not yet written (its turn on the timeline has
    /// not come) — the interleave's one-sample lookahead.
    private var pendingAudio: CMSampleBuffer?

    init(item: DailiesItem, index: Int, count: Int, burnins: DailiesBurnins,
         folder: URL, control: DailiesControl,
         publish: @escaping @Sendable (DailiesProgress) -> Void) {
        self.item = item
        self.index = index
        self.count = count
        self.burnins = burnins
        self.folder = folder
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
                                                       burnins: burnins)
        framesTotal = facts.framesTotal
        // Claimed through the same process-wide reservation every writing
        // path uses, so a daily can never land on a name a take (or another
        // daily) is about to take. Collisions get the app's `_2` suffix.
        let url = CapturePipeline.uniqueURL(
            for: folder.appendingPathComponent(item.outputName)
                .appendingPathExtension("mp4"))
        outputURL = url
        let session = try DailiesSession.open(at: url, facts: facts)
        self.session = session
        publishProgress(force: true)
        try await pump(session, composer: DailiesFrameComposer(
            item: item, burnins: burnins, facts: facts))
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
            }
            try await append(try composer.compose(source, pts: pts),
                             at: pts, session: session)
            framesDone += 1
            // Audio rides behind the picture: everything up to this frame's
            // time goes now, so the writer interleaves without buffering the
            // whole track.
            try await pumpAudio(upTo: pts, session: session)
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
        session.audioInput?.markAsFinished()
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
        while !session.videoInput.isReadyForMoreMediaData {
            guard session.writer.status == .writing else {
                throw DailiesAbort.failed(DailiesSession.failure(of: session.writer))
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
        guard session.adaptor.append(buffer, withPresentationTime: pts) else {
            throw DailiesAbort.failed(DailiesSession.failure(of: session.writer))
        }
    }

    private func pumpAudio(upTo limit: CMTime,
                           session: DailiesSession) async throws {
        guard let output = session.audioOutput,
              let input = session.audioInput else { return }
        while true {
            if pendingAudio == nil {
                pendingAudio = output.copyNextSampleBuffer()
            }
            guard let sample = pendingAudio,
                  CMSampleBufferGetPresentationTimeStamp(sample) <= limit
            else { return }
            while !input.isReadyForMoreMediaData {
                guard session.writer.status == .writing else {
                    throw DailiesAbort.failed(
                        DailiesSession.failure(of: session.writer))
                }
                try? await Task.sleep(for: .milliseconds(2))
            }
            input.append(sample)
            pendingAudio = nil
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
