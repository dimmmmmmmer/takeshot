import Foundation

/// Take lifecycle: starting one (with its pre-roll and its latched audio mask),
/// and closing it — where "closed" means finalized, published to the list, and
/// its drop counts reported. The file's name and the reservation behind it are
/// in `+TakeFiles`; the pre-roll it starts with is in `+PreRoll`.
///
/// Split out of CapturePipeline, which had grown past 1300 lines.
extension CapturePipeline {
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
            takeSlate = config.slate
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
            // the creative side, embedded so it survives a copy that leaves
            // the sidecars behind — see TakeWriter's key documentation
            slate: config.slate,
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
        var take = Take(
            url: writer.url,
            scene: takeSlate.scene,
            roll: takeRoll,
            takeNumber: takeNumber,
            startTimecode: takeStartTC,
            durationSeconds: writer.durationSeconds,
            recordedAt: takeStartedAt)
        take.slate = takeSlate
        return take
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
    ///
    /// This guarantees the FILES — every writer has finished and its moov atom
    /// is on disk. It deliberately does NOT guarantee the publication: each
    /// finalize task hands its take to the main queue and completes without
    /// waiting for that hop, because the exit flush parks the main thread in a
    /// semaphore while it awaits this method — a finalize that waited on main
    /// there would deadlock against it. Callers that need the published take
    /// (the list, the log row) wait for that outcome separately: the tests
    /// poll their collector after this returns, and `flushOnTerminate` drains
    /// the main queue once the semaphore is signalled.
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
