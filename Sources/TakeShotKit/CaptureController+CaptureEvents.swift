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
            if changed, format != nil, self.mirrors.playout != nil {
                self.rebuildPlayout() // re-wires the mirrors on its way out
            } else if changed, format != nil, self.mirrors.ndi != nil {
                // No hardware output, but the NDI frame states the source's
                // frame rate and that rate is captured at wire time.
                self.wireDisplayMirrors()
            }
            if changed { self.reportBitDepthShortfall(format) }
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
        pipeline.onColorimetry = { [weak self] colorimetry in
            guard let self else { return }
            self.signalColorimetry = colorimetry
            self.applyColorimetryToLegend()
        }
        pipeline.onScopeData = { [weak self] data in
            self?.scopes.data = data
        }
        playbackTap.onScopeData = { [weak self] data in
            self?.scopes.data = data
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
        pipeline.onVisualRecReading = { [weak self] reading in
            self?.visualRecReading = reading
        }
    }
    private func handleRecState(_ recording: Bool) {
        isRecording = recording
        // Which trigger fired, read from the health mirror rather than carried on
        // this callback: `beginTake` writes the mirror before it hops to main, so
        // it is already there — and a bundle collected later still finds it,
        // which a callback argument could not provide.
        recTrigger = recording ? pipeline.health.startTrigger : nil
        if recording {
            recordingStartDate = Date()
            recordingMarkers = []
            persistentAlert = nil // a clean start clears the alarm
            // …but a take rolling on embedded fallback instead of the chosen
            // USB source is not a clean start, and must say so (+AudioInput)
            warnIfAudioFellBackAtRecStart()
        } else {
            // a take that outlived its USB device resolves the source now
            reconcileAudioInputAfterTake()
        }
        refreshNameCollision() // start hides it, stop recomputes
        // multicam: the other cameras in sync with the main one
        for channel in extraChannels { channel.setRecording(recording) }
        // Recording protection (hard rule): a running dailies transcode holds
        // between frames while a take rolls and resumes when it ends — it
        // must never compete with TakeWriter for the disk or the encoder.
        dailies.recordingStateChanged(recording)
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
        // the next take of the same scene, when the operator is numbering takes
        // themselves — see CaptureController+Slate
        advanceSlateTake()
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
    /// Say so when the board did not give us the bit depth that was asked for.
    ///
    /// A silent fallback is a colour decision made behind the operator's back:
    /// they selected 12-bit, the board or the mode could not do it, and the
    /// takes come out 10-bit with nothing on screen saying which. The picture
    /// and the footage are still good, so this is a five-second notice rather
    /// than a sticky alarm — but it is never nothing.
    ///
    /// Asked of BOTH samplings. It used to be RGB-only, on the grounds that a
    /// YUV source was 8-bit '2vuy' by design and never a request that could
    /// fail — that stopped being true when 10-bit YCbCr ('v210') became the
    /// default request, and a v210 request that quietly fell back to 8-bit is
    /// exactly the silent colour decision this exists to prevent.
    ///
    /// Only a BOARD can fall short of a request, which is why the demo source is
    /// excluded rather than compared. It generates an 8-bit signal by
    /// construction and nothing ever asked it for more, so measuring it against
    /// the picker would put a notice in front of every operator running --demo
    /// that they could do nothing about. (The RGB-only guard used to exclude it
    /// by accident, the demo format not being flagged 4:4:4.)
    func reportBitDepthShortfall(_ format: CaptureFormat?) {
        guard let format, selectedDeviceID != nil, !isMockSelected,
              let short = Self.bitDepthShortfall(
                  format: format, requested: settings.resolvedCaptureBitDepth)
        else { return }
        lastError = String(format: L("bit_depth_fallback"),
                           short.requested, short.delivered)
    }

    /// Which depth applies to a signal, and whether the board met it — the whole
    /// rule as a value, nil when there is nothing to say.
    ///
    /// Separate from the reporting above because the two halves fail differently:
    /// this one is arithmetic about samplings (one picker, two wire formats, and
    /// 12 on a 4:2:2 wire means 10), and the caller's half is about which sources
    /// the question can even be asked of.
    static func bitDepthShortfall(format: CaptureFormat,
                                  requested: CaptureBitDepth)
        -> (requested: Int, delivered: Int)? {
        let wanted = format.isRGB444 ? requested.bits : requested.yuvBits
        guard format.bitDepth < wanted else { return nil }
        return (requested: wanted, delivered: format.bitDepth)
    }

    func reportPipelineError(_ message: String) {
        let sticky = ["TAKE LOST", "AUDIO LOST", "Dropped", "ingress",
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
