import CaptureCore
import Foundation

/// What the capture reports back, and how it reaches the operator.
///
/// The pipeline's callbacks are wired here, and so is the free-space watchdog,
/// because they end in the same place: `persistentAlert` for anything that
/// threatens footage, a five-second toast for everything else. A failure that
/// costs a take is a sticky alarm, not a toast that scrolls past while the
/// operator is lighting the next setup.
///
/// Split out of `+Capture`, which had grown to hold the session, the bindings
/// and the watchdog at once.
extension CaptureController {
    func bindPipeline() {
        pipeline.onFormatChanged = { [weak self] format in
            guard let self else { return }
            let changed = self.signalFormat != format
            self.signalFormat = format
            if changed, format != nil, self.playoutFeeder != nil {
                self.rebuildPlayout()
            }
        }
        pipeline.onTimecode = { [weak self] timecode in
            guard let self, self.live.currentTimecode != timecode else { return }
            self.live.currentTimecode = timecode
        }
        pipeline.onRecStateChanged = { [weak self] recording in
            self?.handleRecState(recording)
        }
        pipeline.onTakeFinished = { [weak self] take in
            self?.adoptFinishedTake(take)
        }
        pipeline.onSignal = { [weak self] present in
            self?.signalPresent = present
        }
        pipeline.onScopeData = { [weak self] data in
            self?.live.scopeData = data
        }
        playbackTap.onScopeData = { [weak self] data in
            self?.live.scopeData = data
        }
        // capture the monitor object itself: this fires on the pipeline queue
        // and must not touch the MainActor-isolated controller
        let monitor = audioMonitor
        pipeline.onMonitorAudio = { monitor.enqueue($0) }
        pipeline.onError = { [weak self] message in
            self?.reportPipelineError(message)
        }
        pipeline.onVancStats = { [weak self] stats in
            self?.vancStats = stats
        }
        pipeline.onAudioLevels = { [weak self] levels in
            self?.live.audioLevels = levels
        }
    }
    private func handleRecState(_ recording: Bool) {
        isRecording = recording
        if recording {
            recordingStartDate = Date()
            recordingMarkers = []
            persistentAlert = nil // a clean start clears the alarm
        }
        refreshNameCollision() // start hides it, stop recomputes
        // multicam: the other cameras in sync with the main one
        for channel in extraChannels { channel.setRecording(recording) }
        // A card that mounted mid-take waited for this moment rather than
        // putting a prompt on screen during it (see +CardWatch).
        if !recording { drainDeferredCardOffers() }
    }
    /// A finalized take joins the list, the log and the thumbnail queue.
    private func adoptFinishedTake(_ take: Take) {
        var take = take
        take.markers = anchoredMarkers(for: take)
        recordingMarkers = []
        takes.append(take)
        nextTakeNumber += 1
        exportTakeLog()
        requestThumbnail(for: take) // deduped against a cell's request
        flashNewItem(take.url)
    }
    /// Re-anchor marker positions on the take's actual start TC: the wall
    /// clock measured from the REC press is off by the pre-roll.
    private func anchoredMarkers(for take: Take) -> [TakeMarker] {
        recordingMarkers.map { marker in
            var fixed = marker
            // Same conversion the markers sidecar reads back with — one
            // implementation, so a marker cannot land on a different frame
            // depending on whether the app was restarted since.
            //
            // Without a start TC there is nothing to anchor against and the
            // marker's timecode text is the camera's, not an offset: the wall
            // clock measured from the REC press stays.
            if take.startTimecode != nil,
               let seconds = TakeLogExporter.markerSeconds(
                   timecodeText: marker.timecodeText,
                   start: take.startTimecode) {
                fixed.seconds = seconds
            }
            return fixed
        }
    }
    /// Recording-integrity failures stick in the alarm banner; everything else
    /// toasts for five seconds.
    ///
    /// "Failed to start recording" and a take truncated by a format change used
    /// to toast: the two cases where footage is missing outright, announced more
    /// quietly than a dropped frame. An operator watching the slate rather than
    /// the screen had no way to learn about them.
    func reportPipelineError(_ message: String) {
        let sticky = ["TAKE LOST", "Dropped", "ingress",
                      "Failed to start recording", "Take closed:",
                      "Pre-roll incomplete"]
        if sticky.contains(where: message.contains) {
            persistentAlert = message
        } else {
            lastError = message
        }
    }

    // MARK: - free space

    /// Free-space watch on the record volume: warn early, stop the take
    /// before the writer hits a hard wall (nothing watched disk space at all).
    func startDiskWatch() {
        Task { [weak self] in
            while let self, !Task.isCancelled {
                self.checkDiskSpace()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }
    private func checkDiskSpace() {
        guard isCapturing else { return }
        let values = try? destinationRoot.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let free = values?.volumeAvailableCapacityForImportantUsage
        else {
            // Asking a volume that is no longer mounted is exactly how this
            // query fails, so returning quietly meant the watchdog went silent
            // in the one case it exists for. A take still "recording" onto a
            // vanished destination writes nothing at all.
            // A merely absent folder is recoverable and normal (a fresh
            // destination path), so try that first and only alarm if the
            // volume itself is unreachable.
            try? FileManager.default.createDirectory(
                at: destinationRoot, withIntermediateDirectories: true)
            guard !FileManager.default.fileExists(atPath: destinationRoot.path)
            else { return }
            if isRecording {
                pipeline.toggleManualRecord()
                persistentAlert = "RECORD VOLUME UNREACHABLE — recording stopped"
            } else {
                persistentAlert = "Record folder unreachable: "
                    + destinationRoot.path
            }
            return
        }
        let freeGB = Double(free) / 1_000_000_000
        if freeGB < 0.5, isRecording {
            pipeline.toggleManualRecord() // close the take while it can finalize
            persistentAlert = String(format:
                "DISK FULL (%.1f GB) — recording stopped", freeGB)
        } else if freeGB < 5 {
            persistentAlert = String(format:
                "Record disk low: %.1f GB free", freeGB)
        }
    }
}
