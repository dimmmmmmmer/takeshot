import Foundation

/// Take lifecycle: starting one (with its pre-roll and its latched audio mask),
/// and closing it — where "closed" means finalized, published to the list, and
/// its drop counts reported. The file's name and the reservation behind it are
/// in `+TakeFiles`; the pre-roll it starts with is in `+PreRoll`.
///
/// Split out of CapturePipeline, which had grown past 1300 lines.
extension CapturePipeline {
    /// `trigger` is what opened the take, recorded so a spurious roll can be
    /// diagnosed on set: it goes into the health mirror, and from there onto the
    /// REC indicator over the player and into the diagnostics bundle. Manual by
    /// default because the button, the hotkey and the remote all come through
    /// `toggleManualRecord`; the detector's own answer is passed in by
    /// `runDetector`.
    func beginTake(timecode rawTimecode: Timecode?, recStartIndex: Int? = nil,
                   trigger: RecTrigger = .manual) {
        guard writer == nil, let format else { return }
        // Latched for the take, and it is the EFFECTIVE mask — the operator's
        // channels when they have chosen any, and what the meters measured
        // carrying a stream during standby when they have not (see
        // `AudioChannelDetector`). Latched for the same reason it always was:
        // the writer's channel count is fixed at start, so a mask that moved
        // under an open file would desync the trim from the track.
        recordingMask = effectiveAudioChannelMask
        takeColorimetry = signalColorimetry            // …and so is this
        // …and the chroma key, values and all. Not merely tidiness like the
        // slate: the record buffer's PIXEL FORMAT follows this answer, and
        // AVAssetWriter does not survive that changing under an open session —
        // so an operator who disarms the bake mid-take finishes the take they
        // started, and one who arms it mid-take bakes the NEXT one. The key's
        // values are latched with the flag for the reason the colorimetry is:
        // a tolerance dragged mid-take would move which pixels are the plate
        // halfway through one file, and a file that changes what it is in the
        // middle is worse than either version of it.
        takeChromaKey = recordChromaKey
        takeChromaRecord = recordChromaKey.record && recordChromaKey.isOn
        // …and the LUT bake, for exactly the same reason and it was NOT latched:
        // `recordProduct` read `lutRecord` per frame, so the switch handed the
        // writer BGRA display frames while it was on and the wire-code record
        // buffer while it was off — a pixel-format change inside an open
        // AVAssetWriter session. The `lutKey` tag is written just below, once,
        // so a take that changed halfway also lied about itself.
        //
        // The filter and the name are latched with the flag, not out of
        // tidiness: a look swapped mid-take would put two grades in one file,
        // and the tag would name whichever was selected at the start.
        takeLUTRecord = lutRecord
        takeLUTFilter = lutFilter
        takeLUTName = lutName
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
            gapFilledAudioPackets = 0
            reportedAudioConform = false
            reportedAudioStarved = false
            mirroredAudioDrops = 0
            mirroredAudioPadding = 0
            noteHealth {
                $0.isRecording = true
                $0.startTrigger = trigger
                $0.takeFileName = url.lastPathComponent
                $0.droppedVideoFramesInTake = 0
                $0.droppedAudioPacketsInTake = 0
                $0.gapFilledAudioPacketsInTake = 0
                $0.paddedAudioPacketsInTake = 0
            }
            lastExternalAudioEnd = nil
            preRolledAudioEnd = nil
            // from here on the take is answerable for its input: a board that
            // stops calling back has to be noticed by a clock (see
            // `+FrameWatchdog`), and the timer exists only while one is open
            startFrameWatchdog()
            warnIfTakeHasNoAudioTrack(url: url)
            drainPreRoll(into: writer, startIndex: startIndex)
            DispatchQueue.main.async { self.onRecStateChanged?(true) }
        } catch {
            DispatchQueue.main.async {
                self.onError?(.recordingStartFailed(
                    reason: error.localizedDescription))
            }
        }
    }

    private func makeTakeWriter(url: URL, format: CaptureFormat,
                                timecode: Timecode?) throws -> TakeWriter {
        try TakeWriter(
            url: url, format: format,
            codec: config.settings.capture.codec, startTimecode: timecode,
            markerMetadata: {
                var meta = [
                    TakeWriter.rollKey: config.roll,
                    TakeWriter.clipKey: String(config.takeNumber),
                    TakeWriter.frameRateKey: String(format.frameRate),
                ]
                // tag a file with a baked-in LUT: playback won't apply the LUT again
                if takeLUTRecord, let takeLUTName {
                    meta[TakeWriter.lutKey] = takeLUTName
                }
                // …and a file whose picture is a COMPOSITE, with what went
                // behind the actor. Not to stop the app applying it twice — a
                // key is never applied on playback — but because this is the one
                // fact about such a file that cannot be recovered from the
                // picture: it says "this is not camera original" to post, to the
                // operator reviewing it, and to a future reader of this app.
                if takeChromaRecord {
                    meta[TakeWriter.chromaKeyKey] = takeChromaKey.background.rawValue
                }
                // …and with what its code values mean, so the player expands
                // the take exactly as the monitor expanded the wire. A baked
                // LUT is rendered on the display buffer, so that take carries
                // display values whatever the wire was doing — and so is a
                // baked key, which is why one predicate answers for both.
                //
                // The answer comes from the levels stage, i.e. from frames that
                // have already been through it. A take opened before the first
                // frame of a session — REC pressed inside the 40 ms between
                // format detection and frame one — cannot know, and says
                // nothing rather than guessing: unexpanded is a slightly washed
                // take, and expanding one that should not be crushes it.
                if recordCarriesWireCodes, !recordBakesDisplayBuffer {
                    meta[TakeWriter.levelsKey] = TakeWriter.wireValue
                }
                return meta
            }(),
            // the creative side, embedded so it survives a copy that leaves
            // the sidecars behind — see TakeWriter's key documentation
            slate: config.slate,
            // What the file says its codes mean comes from the SIGNAL and from
            // nowhere else. The record buffer holds the wire's codes (the
            // wire-code rule is untouched by HDR), so a PQ or HLG take tagged
            // Rec.709 would be read a hundred times too dark or too bright by
            // every tool downstream. Latched with the take, so a camera that
            // switches transfer mid-take cannot retag the frames already
            // written; nil is Rec.709, which is what an SDR wire is.
            //
            // `settings.capture.colorTagPreset` used to be the fallback here.
            // It has had no writer since its picker was deleted, so it was
            // permanently nil and this was already always Rec.709 — see the
            // field, which is a tombstone now rather than a claim about a
            // choice the operator has.
            colorTagPreset: takeColorimetry.filePreset,
            displayMetadata: takeColorimetry.displayMetadata,
            audioChannelCount: recordChannelCount(under: recordingMask))
    }

    /// The writer's audio input is created from the channel count learned
    /// from the first audio packet. A take that starts before any packet
    /// has arrived — relaunch or device restart while the camera is
    /// already rolling, where a VANC trigger fires on capture frame 1 —
    /// gets no audio input at all, and every packet of the take is then
    /// discarded without a counter. Say so: silent scratch audio is only
    /// discovered in the edit.
    private func warnIfTakeHasNoAudioTrack(url: URL) {
        guard recordChannelCount(under: recordingMask) == 0 else { return }
        DispatchQueue.main.async {
            self.onError?(.takeLostNoAudioTrack(file: url.lastPathComponent))
        }
    }

    func finishTake() {
        guard let writer else { return }
        self.writer = nil
        // **The detector is told, whatever closed the take.** It sets itself
        // false on its own `.stopped` event and nowhere else — so a take closed
        // by a writer failure, a failed start, a disk-full stop or a relay left
        // it believing it was still recording, and `vancEvent` ignores a start
        // while recording. The camera never stopped rolling; the operator
        // swapped the full drive; nothing recorded until the camera stopped and
        // started again, and no alarm said auto-detection was suspended.
        // Idempotent on the detector's own path: it is already false there.
        detector.setRecording(false)
        // Nothing left for the watchdog to protect, and it must not fire between
        // takes — including when it is the watchdog itself that got us here.
        stopFrameWatchdog()
        // Last chance to read the writer's audio tallies on the queue that owns
        // them: no more packets can arrive now, and the finalize below runs on a
        // task of its own. The conform one is read here as well as per packet,
        // for the take whose source moved and then went quiet — there would be
        // no later packet to notice it on.
        noteAudioDrops(from: writer)
        noteAudioConform(from: writer)
        noteAudioPadding(from: writer)
        noteHealth {
            $0.isRecording = false
            $0.takeFileName = nil
            $0.takesClosed += 1
        }
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
        let gapFilledAudio = gapFilledAudioPackets
        let task = Task { [weak self] in
            defer { self?.prunePendingFinish(finishID) }
            do {
                _ = try await writer.finish()
                // the callbacks are read here, on the task, and only the
                // resulting values cross to main — sending `self` itself into a
                // main-actor closure is what Swift 6 rightly objects to
                Self.publish(take, report: self?.takeReport,
                             droppedAudio: writer.droppedAudioPackets,
                             gapFilledAudio: gapFilledAudio,
                             droppedVideo: droppedVideo)
            } catch {
                // The half-written file keeps the com.takeshot.origin tag from
                // its initial moov, so the folder scan re-adopts it within
                // seconds and it sits in the panel looking like a healthy take.
                // It is not deleted — with fragmented moov atoms most of it is
                // usually still recoverable — but it must not pass for good
                // footage in the panel or in the log handed to post.
                let marked = Self.markFailed(take.url)
                self?.noteHealth { $0.takesFailedToFinalize += 1 }
                let report = self?.takeReport
                DispatchQueue.main.async {
                    report?.failed(.takeLostFinalizeFailed(
                        file: marked.deletingPathExtension().lastPathComponent,
                        reason: error.localizedDescription))
                }
            }
        }
        pendingFinishTasks[finishID] = task
        // an audio-source switch that arrived mid-take waited for the latched
        // writer to close; it applies now, before the next take can start
        if let pending = pendingAudioSourceSwitch {
            applyAudioSourceSwitch(pending.kind,
                                   expectedChannels: pending.expectedChannels)
        }
    }

    /// A finalized take and its tallies, handed to the main queue.
    ///
    /// The counts are reported even when the live alarm already fired for them:
    /// the alarm is a warning while the take is running (and the video one only
    /// fires on SUSTAINED loss), and this is the take's total — quietly stated,
    /// but never hidden. Static, and given only values, so nothing sends the
    /// pipeline itself into a main-actor closure.
    private static func publish(_ take: Take, report: TakeReport?,
                                droppedAudio: Int, gapFilledAudio: Int,
                                droppedVideo: Int) {
        DispatchQueue.main.async {
            report?.finished(take)
            if droppedAudio > 0 {
                report?.failed(.takeDroppedAudioPackets(
                    take: take.displayName, count: droppedAudio))
            }
            if gapFilledAudio > 0 {
                report?.failed(.takeGapFilledAudio(
                    take: take.displayName, count: gapFilledAudio))
            }
            if droppedVideo > 0 {
                report?.failed(.takeDroppedVideoFrames(
                    take: take.displayName, count: droppedVideo))
            }
        }
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
            recordedAt: takeStartedAt,
            frameRate: writer.format.frameRate)
        take.slate = takeSlate
        take.comment = audioNotes(from: writer).joined(separator: "; ")
        return take
    }

    /// What the take's log row says happened to its sound. A take whose audio
    /// went wrong and says nothing is exactly the silent failure the integrity
    /// rules exist to prevent — it is found in the edit.
    ///
    /// English, and staying English even though the alarms beside these are now
    /// localized: this is not a message to the operator, it is the Comments
    /// column of `takeshot-log.csv` and of the ALE, whose schema is frozen and
    /// whose reader is post-production. A row that said "Звук USB потерян"
    /// because the operator had the UI in Russian would be a different value in
    /// a machine-read column.
    private func audioNotes(from writer: TakeWriter) -> [String] {
        var notes: [String] = []
        if gapFilledAudioPackets > 0 {
            notes.append("USB audio lost — \(gapFilledAudioPackets) "
                + "packet(s) padded with silence")
        }
        if writer.paddedAudioPackets > 0 {
            // Its own line rather than folded into the one above: that one says
            // a working source went quiet, this one says the track was never fed
            // — post is laying out sound either way, and which of the two
            // happened decides who gets asked about it.
            notes.append("audio track starved — \(writer.paddedAudioPackets) "
                + "packet(s) padded with silence")
        }
        if writer.conformedAudioPackets > 0 {
            // the channel MAP after the change is a guess, which is the part
            // post has to know before it starts laying the tracks out
            notes.append("audio channel count changed mid-take — "
                + "\(writer.conformedAudioPackets) packet(s) conformed")
        }
        return notes
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
