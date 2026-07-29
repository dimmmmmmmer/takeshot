@preconcurrency import Accelerate
@preconcurrency import AVFoundation
@preconcurrency import CoreImage
@preconcurrency import CoreMedia
@preconcurrency import CoreVideo
import Foundation
import os.log

/// Take lifecycle: starting one (with its pre-roll), closing it, and the
/// name reservation that keeps two pipelines off the same file.
///
/// Split out of CapturePipeline, which had grown past 1300 lines.
extension CapturePipeline {
    /// Keep the pre-roll window's audio, trimmed to a little more than the
    /// window itself. Raw packets: the channel mask is latched when the take
    /// starts, so the trim happens at drain time. ~60 KB per 40 ms packet at
    /// 16 channels, so even a long lead costs single-digit megabytes.
    /// Write the buffered pre-roll audio into a take that has just started,
    /// trimmed with the mask latched for this take. Packets older than the
    /// take's first video frame have nowhere to go and are discarded.
    private func drainPreRollAudio(into writer: TakeWriter, from start: CMTime?) {
        defer { preRollAudio.removeAll() }
        guard let start else { return }
        for buffered in preRollAudio where buffered.pts >= start {
            var toWrite: CMSampleBuffer? = buffered.buffer
            if let mask = recordingMask {
                let indices = (0..<32).filter { mask & (1 << $0) != 0 }
                toWrite = PCMAudio.selectChannels(buffered.buffer, indices: indices,
                                                  formatCache: &trimFormatCache)
            }
            if let toWrite { writer.append(audioSampleBuffer: toWrite) }
        }
    }
    func bufferPreRollAudio(_ sampleBuffer: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid else { return }
        preRollAudio.append((pts: pts, buffer: sampleBuffer))
        let fps = format?.frameRate ?? 25
        let window = Double(preRollFrames) / max(1, fps) + 1.0 // slack for jitter
        while let first = preRollAudio.first,
              (pts - first.pts).seconds > window {
            preRollAudio.removeFirst()
        }
    }
    public static func uniqueURL(for url: URL) -> URL {
        reservationLock.lock()
        defer { reservationLock.unlock() }

        func taken(_ candidate: URL) -> Bool {
            FileManager.default.fileExists(atPath: candidate.path)
                || reservedPaths.contains(candidate.path)
        }

        if !taken(url) {
            reservedPaths.insert(url.path)
            return url
        }
        let base = url.deletingPathExtension()
        let ext = url.pathExtension
        var attempt = 2
        while attempt < 1000 {
            let candidate = URL(fileURLWithPath: base.path + "_\(attempt)")
                .appendingPathExtension(ext)
            if !taken(candidate) {
                reservedPaths.insert(candidate.path)
                return candidate
            }
            attempt += 1
        }
        let fallback = URL(fileURLWithPath: base.path + "_\(UUID().uuidString)")
            .appendingPathExtension(ext)
        reservedPaths.insert(fallback.path)
        return fallback
    }
    /// Drop a reservation once the file exists on disk (or the take failed to
    /// start) — from then on the filesystem itself is the authority.
    public static func releaseReservation(for url: URL) {
        reservationLock.lock()
        reservedPaths.remove(url.path)
        reservationLock.unlock()
    }
    func beginTake(timecode rawTimecode: Timecode?, recStartIndex: Int? = nil) {
        guard writer == nil, let format else { return }
        recordingMask = config.settings.audioChannelMask // latched for the take
        let startIndex = recStartIndex ?? frameIndex
        let timecode = preRollShiftedTimecode(rawTimecode, startIndex: startIndex)
        // takes are never overwritten: on a name collision — suffix _2, _3…
        // (typical case: the clip counter restarted and last session's files with
        // the same names are already in the folder)
        let url = Self.uniqueURL(for: takeFileURL(timecode: timecode))
        // the writer creates the file straight away, so the filesystem takes
        // over from the reservation whichever way this goes
        defer { Self.releaseReservation(for: url) }
        do {
            let writer = try makeTakeWriter(url: url, format: format,
                                            timecode: timecode)
            self.writer = writer
            takeStartTC = timecode
            takeStartedAt = Date()
            takeScene = config.scene
            takeRoll = config.roll
            takeNumber = config.takeNumber
            droppedFrames = 0
            warnIfTakeHasNoAudioTrack(url: url)
            drainPreRoll(into: writer, startIndex: startIndex)
            DispatchQueue.main.async { self.onRecStateChanged?(true) }
        } catch {
            DispatchQueue.main.async {
                self.onError?("Failed to start recording: \(error.localizedDescription)")
            }
        }
    }

    /// The file's TC track counts from its FIRST frame — which is pre-roll,
    /// shot before the camera's TC started running. Shift the start TC back
    /// by the pre-roll frames actually written, so the camera-start frame
    /// carries exactly the camera's TC and the take stays sync-accurate
    /// against the camera original.
    private func preRollShiftedTimecode(_ rawTimecode: Timecode?,
                                        startIndex: Int) -> Timecode? {
        let cutoffPreview = max(0, startIndex - preRollFrames)
        // only the frames written BEFORE the camera-start frame shift the TC —
        // counting the detection-latency frames too made every take a few
        // frames early against the camera original
        let preStartCount = preRollBuffer.filter {
            $0.index >= cutoffPreview && $0.index < startIndex
        }.count
        guard let tc = rawTimecode, preStartCount > 0 else { return rawTimecode }
        let dayFrames = Timecode.dayFrames(fps: tc.fps,
                                           isDropFrame: tc.isDropFrame)
        var shifted = tc.frameNumber - preStartCount
        if shifted < 0 { shifted += dayFrames } // wrap across midnight
        return Timecode(frameNumber: shifted,
                        fps: tc.fps, isDropFrame: tc.isDropFrame)
    }

    /// The take's path from the naming template, before the collision suffix.
    private func takeFileURL(timecode: Timecode?) -> URL {
        let engine = NamingEngine(template: config.settings.namingTemplate)
        let context = NamingContext(
            project: config.settings.projectName,
            date: Date(),
            scene: config.scene,
            take: config.takeNumber,
            reel: config.roll,
            camera: config.settings.cameraLabel,
            clipName: "",
            postfix: config.settings.postfix ?? "",
            clipPadding: config.settings.clipPadWidthEffective,
            timecode: timecode)
        let root = URL(fileURLWithPath:
            (config.settings.destinationPath as NSString).expandingTildeInPath)
        // write STRAIGHT into the chosen folder — no auto subfolders by date/project:
        // the DIT picks the card/roll folder themselves; app nesting surprises them.
        return root
            .appendingPathComponent(engine.fileName(for: context))
            .appendingPathExtension("mov")
    }

    private func makeTakeWriter(url: URL, format: CaptureFormat,
                                timecode: Timecode?) throws -> TakeWriter {
        try TakeWriter(
            url: url, format: format,
            codec: config.settings.codec, startTimecode: timecode,
            markerMetadata: {
                var meta = [
                    TakeWriter.rollKey: config.roll,
                    TakeWriter.clipKey: String(config.takeNumber),
                ]
                // tag a file with a baked-in LUT: playback won't apply the LUT again
                if lutRecord, let lutName {
                    meta[TakeWriter.lutKey] = lutName
                }
                return meta
            }(),
            colorTagPreset: config.settings.colorTagPreset,
            audioChannelCount: recordChannelCount)
    }

    /// The writer's audio input is created from the channel count learned
    /// from the first audio packet. A take that starts before any packet
    /// has arrived — relaunch or device restart while the camera is
    /// already rolling, where a VANC trigger fires on capture frame 1 —
    /// gets no audio input at all, and every packet of the take is then
    /// discarded without a counter. Say so: silent scratch audio is only
    /// discovered in the edit.
    private func warnIfTakeHasNoAudioTrack(url: URL) {
        guard recordChannelCount == 0 else { return }
        DispatchQueue.main.async {
            self.onError?("TAKE LOST audio — \(url.lastPathComponent) "
                + "started before the audio format was known and has no "
                + "audio track")
        }
    }

    /// pull frames from the buffer from (camera start - pre-roll) to current;
    /// in Rec Run their timecode is frozen at the start value, so the take's
    /// timecode track stays correct
    private func drainPreRoll(into writer: TakeWriter, startIndex: Int) {
        let cutoff = max(0, startIndex - preRollFrames)
        // the burst outruns the encoder queue — wait, but within a total
        // budget: unbounded waits stall the pipeline queue while capture
        // callbacks pile up retained 4K frames behind it
        let drainDeadline = Date().addingTimeInterval(1.5)
        var lostPreRoll = 0
        var firstPreRollPTS: CMTime?
        for buffered in preRollBuffer where buffered.index >= cutoff {
            let frame = lutRecord
                ? (applyLUT(to: buffered.pixelBuffer) ?? buffered.pixelBuffer)
                : buffered.pixelBuffer
            if writer.appendBuffered(pixelBuffer: frame, pts: buffered.pts,
                                     deadline: drainDeadline) {
                if firstPreRollPTS == nil { firstPreRollPTS = buffered.pts }
            } else {
                lostPreRoll += 1
            }
        }
        preRollBuffer.removeAll()
        // ...and the sound that goes under those frames. The writer's session
        // starts at the first video PTS above, so anything older than that
        // cannot be placed and is dropped.
        drainPreRollAudio(into: writer, from: firstPreRollPTS)
        // once the drain budget is spent the rest of the burst is dropped —
        // and those are the frames closest to the camera's REC press, the
        // whole point of pre-roll. Silence here reads as a clean head.
        if lostPreRoll > 0 {
            let count = lostPreRoll
            DispatchQueue.main.async {
                self.onError?("Pre-roll incomplete: \(count) frame(s) "
                    + "before the REC point were not written")
            }
        }
    }
    static func markFailed(_ url: URL) -> URL {
        let name = url.deletingPathExtension().lastPathComponent
        guard !name.hasSuffix(failedTakeSuffix) else { return url }
        let renamed = url.deletingLastPathComponent()
            .appendingPathComponent(name + failedTakeSuffix)
            .appendingPathExtension(url.pathExtension)
        let target = uniqueURL(for: renamed)
        do {
            try FileManager.default.moveItem(at: url, to: target)
            return target
        } catch {
            return url
        }
    }
    func finishTake() {
        guard let writer else { return }
        self.writer = nil
        let take = describeTake(from: writer)
        DispatchQueue.main.async {
            self.onRecStateChanged?(false)
        }
        // the take joins the list only after a SUCCESSFUL finalize — a failed
        // finish used to leave a normal-looking, unplayable file in the panel
        // pruned by the task itself: the handles are only awaited at capture
        // stop and at quit, and a shooting day never stops capture — the list
        // would otherwise hold one handle per take until the app exits
        let finishID = nextFinishID
        nextFinishID += 1
        let droppedVideo = droppedFrames
        let task = Task { [weak self] in
            defer { self?.prunePendingFinish(finishID) }
            do {
                _ = try await writer.finish()
                let droppedAudio = writer.droppedAudioPackets
                // the callbacks are read here, on the task, and only the
                // resulting values cross to main — sending `self` itself into a
                // main-actor closure is what Swift 6 rightly objects to
                let report = self?.takeReport
                DispatchQueue.main.async {
                    report?.finished(take)
                    if droppedAudio > 0 {
                        report?.failed("Take \(take.displayName): "
                            + "\(droppedAudio) audio packet(s) dropped")
                    }
                    // the live alarm only fires on sustained loss, so the take's
                    // real total is stated here — quietly, but never hidden
                    if droppedVideo > 0 {
                        report?.failed("Take \(take.displayName): "
                            + "\(droppedVideo) video frame(s) dropped")
                    }
                }
            } catch {
                // The half-written file keeps the com.takeshot.origin tag from
                // its initial moov, so the folder scan re-adopts it within
                // seconds and it sits in the panel looking like a healthy take.
                // It is not deleted — with fragmented moov atoms most of it is
                // usually still recoverable — but it must not pass for good
                // footage in the panel or in the log handed to post.
                let marked = Self.markFailed(take.url)
                let report = self?.takeReport
                DispatchQueue.main.async {
                    report?.failed("TAKE LOST — failed to finalize "
                        + "\(marked.deletingPathExtension().lastPathComponent): "
                        + error.localizedDescription)
                }
            }
        }
        pendingFinishTasks[finishID] = task
    }

    /// The take as the app will list it, snapshotted from the writer before the
    /// finalize task takes it away.
    private func describeTake(from writer: TakeWriter) -> Take {
        Take(
            url: writer.url,
            displayName: writer.url.deletingPathExtension().lastPathComponent,
            scene: takeScene,
            roll: takeRoll,
            takeNumber: takeNumber,
            startTimecode: takeStartTC,
            durationSeconds: writer.durationSeconds,
            recordedAt: takeStartedAt)
    }

    /// Drop a finished task's handle, back on the pipeline queue that owns the
    /// list. Called from the task's own `defer`, so it must tolerate the
    /// pipeline having gone away first.
    private func prunePendingFinish(_ finishID: Int) {
        queue.async {
            self.pendingFinishTasks.removeValue(forKey: finishID)
        }
    }
    /// Await finalization of all files still being written (capture stop, exit).
    public func finishPendingWrites() async {
        let tasks: [Task<Void, Never>] = await withCheckedContinuation { cont in
            queue.async {
                let snapshot = Array(self.pendingFinishTasks.values)
                self.pendingFinishTasks.removeAll()
                cont.resume(returning: snapshot)
            }
        }
        for task in tasks { await task.value }
    }
}
