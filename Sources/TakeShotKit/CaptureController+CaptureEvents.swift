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
    /// The playback tap's own callbacks. Split out of `bindPipeline` because
    /// they are a different producer: the tap runs over a clip under review,
    /// not over the board.
    func bindPlaybackTap() {
        playbackTap.onLevelsFallback = { [weak self] in
            self?.lastError = L("playback_levels_fallback")
        }
        playbackTap.onScopeData = { [weak self] data in
            guard let self, self.syncPlay == nil else { return }
            self.scopes.data = data
        }
    }

    func bindPipeline() {
        pipeline.onFormatChanged = { [weak self] format in
            guard let self else { return }
            let changed = self.signalFormat != format
            self.signalFormat = format
            if changed, format != nil, self.mirrors.playout != nil {
                self.rebuildPlayout() // re-wires the mirrors on its way out
            } else if changed, format != nil,
                      self.mirrors.srt != nil || self.mirrors.ndi != nil {
                // No hardware output, but both of the remaining outputs care
                // about the rate and both capture it at wire time: the SRT
                // encoder is BUILT for a raster and a frame rate, and an NDI
                // frame STATES the source's rate on the wire.
                self.wireDisplayMirrors()
            }
            if changed { self.reportBitDepth(format) }
            // The first real rate is the first chance to turn a LEGACY seconds
            // pre-roll into the frame count it means. Once. After it the
            // number is stored and a later rate change cannot move it.
            if let format { self.settleLegacyPreRoll(atFrameRate: format.frameRate) }
        }
        pipeline.onTimecode = { [weak self] timecode in
            guard let self, self.live.currentTimecode != timecode else { return }
            self.live.currentTimecode = timecode
            // The grid picture's burned-in clocks and nameplates ride this
            // tick: it is already the once-per-frame edge the whole app
            // reads the running timecode off, it is already deduplicated,
            // and it returns on a nil check when nobody is watching the grid.
            self.pushGridIdentities()
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
        // The tap hands its trace over on the MAIN queue, so a frame analyzed a
        // moment before a grid opened can still land after `updateScopesRunning`
        // has cleared the panel — one stale measurement of the parked take,
        // arriving under four others and staying there because nothing else is
        // producing. Refusing it here rather than relying on the clear winning
        // the race is what makes "a grid is measured by nothing" a property of
        // the app instead of a property of the ordering.
        bindPlaybackTap()
        bindAudioReporting()
        pipeline.onError = { [weak self] alarm in
            self?.reportPipelineError(alarm)
        }
        pipeline.onVancStats = { [weak self] stats in
            self?.vancStats = stats
        }
        pipeline.onVisualRecReading = { [weak self] reading in
            self?.visualRecReading = reading
        }
    }

    /// What the audio path reports, on its own three publishers.
    ///
    /// Its own function because the three answer at three different rates and
    /// the split is the whole point: the monitor feed arrives on the pipeline
    /// queue, the meters on main at packet rate, and the channel measurement a
    /// handful of times a session. Wiring them together above also pushed
    /// `bindPipeline` past the house function length, which is the kind of
    /// nudge worth taking rather than silencing.
    private func bindAudioReporting() {
        // capture the monitor object itself: this fires on the pipeline queue
        // and must not touch the MainActor-isolated controller
        let monitor = audioMonitor
        pipeline.onMonitorAudio = { monitor.enqueue($0) }
        pipeline.onAudioLevels = { [weak self] in self?.adoptAudioLevels($0) }
        // Which channels are carrying a stream (see `AudioChannelDetector`) —
        // nil when the measurement has no answer, which is what the panel reads
        // as "listening" and what leaves every declared channel recorded.
        pipeline.onAudioChannelsDetected = { [weak self] mask in
            self?.detectedAudioChannelMask = mask
        }
    }

    /// The meters, and — on its own publisher and only when it MOVES — how many
    /// channels the signal is carrying.
    ///
    /// The two are split because they change at completely different rates. The
    /// levels arrive with every packet, ~25 times a second, which is why they
    /// live on `LiveSignal` and only the meters observe them. The COUNT changes
    /// when the signal does, a handful of times a shift, and the LTC channel
    /// menu is built from it — a menu that observed `LiveSignal` to read
    /// `audioLevels.count` would re-lay out at meter rate, which is the ~1 CPU
    /// core of SwiftUI layout that object exists to prevent.
    private func adoptAudioLevels(_ levels: [Float]) {
        live.audioLevels = levels
        guard audioChannelCount != levels.count else { return }
        audioChannelCount = levels.count
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
        // The REC lamps in the composed grid. Pushed here as well as on the
        // timecode tick because a take can roll on a signal carrying no
        // timecode at all (manual detection), and that tick would then have
        // fired once at startup and never again.
        pushGridIdentities()
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
    /// What the signal's own bit depth did to this capture, said out loud.
    ///
    /// Depth follows the signal now, and that removed a wrong answer and added a
    /// duty. The operator no longer chooses, so the app owes them BOTH ends of
    /// what the wire decided on their behalf: the depth it could not keep up
    /// with, and the depth it went to without being asked.
    ///
    /// A five-second notice rather than a sticky alarm in both cases — the
    /// picture and the footage are good either way — but never nothing.
    ///
    /// Only a BOARD is measured, which is why the demo source is excluded rather
    /// than compared. It generates an 8-bit signal by construction and reports no
    /// source depth at all, so there is nothing to measure; the guard is kept
    /// explicit because a notice on every launch of the demo is how an operator
    /// learns to ignore the banner that matters.
    func reportBitDepth(_ format: CaptureFormat?) {
        guard let format, selectedDeviceID != nil, !isMockSelected,
              let notice = Self.bitDepthNotice(format: format,
                                               codec: settings.capture.codec)
        else { return }
        lastError = notice.localizedText
    }

    /// What is worth saying about a signal's depth, as a value. nil is silence,
    /// which is the common case.
    ///
    /// Separate from the reporting above because the two halves fail differently:
    /// this one is arithmetic about samplings and codecs, and the caller's half
    /// is about which sources the question can be asked of at all.
    ///
    /// The two cases are mutually exclusive by construction — a shortfall means
    /// the delivered depth is below what the wire could give, and the deep-path
    /// case IS the deepest the wire goes — so the order below is a reading
    /// order and not a precedence rule.
    static func bitDepthNotice(format: CaptureFormat,
                               codec: CaptureCodec) -> BitDepthNotice? {
        if let capturable = format.capturableBitDepth, format.bitDepth < capturable {
            return .shortfall(source: capturable, delivered: format.bitDepth)
        }
        guard format.bitDepth >= 12 else { return nil }
        return .twelveBit(codec: codec)
    }

    /// The two things a signal's depth can be worth telling the operator.
    ///
    /// A value rather than two format-string call sites for the same reason
    /// `DiskVerdict` is: the rule can then be stated and checked without a board,
    /// and the words are chosen somewhere else.
    enum BitDepthNotice: Equatable {
        /// The wire is carrying more than the app could open. `source` is what
        /// the signal can actually yield at its sampling, so a 12-bit YCbCr
        /// source captured as 'v210' is NOT this — ten is all a 4:2:2 wire has
        /// (see `CaptureFormat.capturableBitDepth`).
        case shortfall(source: Int, delivered: Int)
        /// The signal put this capture on 12-bit 'R12B' with nobody choosing it.
        ///
        /// This case exists because auto-depth created it. 12-bit used to need a
        /// deliberate click, so the heaviest path in the app — twice the record
        /// bandwidth, twice the pre-roll ring per frame, and a sampling only
        /// ProRes 4444 can carry — was always something the operator had already
        /// agreed to. Now a camera can put them there between setups, and the
        /// one thing they must not do is find out in the edit.
        case twelveBit(codec: CaptureCodec)

        var localizedText: String {
            switch self {
            case .shortfall(let source, let delivered):
                return String(format: L("bit_depth_fallback"), source, delivered)
            case .twelveBit(let codec):
                // The codec half is the actionable one: 12-bit RGB 4:4:4 into a
                // 4:2:2 codec is subsampled on the way in, and that used to be a
                // consequence of the operator's own click.
                guard !codec.isRGB444Capable else { return L("bit_depth_twelve") }
                return String(format: L("bit_depth_twelve_subsampled"),
                              codec.rawValue)
            }
        }
    }

    /// Put a pipeline alarm in front of the operator, in the register the alarm
    /// itself declares and in the language the app is set to.
    ///
    /// Recording-integrity failures stick in the alarm banner; everything else
    /// toasts for five seconds. "Failed to start recording" and a take truncated
    /// by a format change used to toast: the two cases where footage is missing
    /// outright, announced more quietly than a dropped frame. An operator
    /// watching the slate rather than the screen had no way to learn about them.
    ///
    /// This used to read the register off the prose — a list of English
    /// substrings ("TAKE LOST", "Dropped", "ingress") matched against the
    /// message — which made the wording load-bearing and the messages
    /// untranslatable: localizing them would have quietly demoted every
    /// take-loss alarm to a five-second toast. The severity now travels with
    /// the event (`PipelineAlarm.severity`) and the words are chosen separately
    /// (`AlarmLocalization`), so the two can move independently.
    ///
    /// `camera` is a multicam channel's letter. The label is added here rather
    /// than in `CameraChannel` because it is presentation: a B-cam take is a
    /// take, and prefixing must not be able to change what register it lands
    /// in — which, under a substring classifier, is exactly the kind of thing
    /// that could.
    func reportPipelineError(_ alarm: PipelineAlarm, camera: String? = nil) {
        let text = Self.tagged(alarm.localizedText, source: camera)
        switch alarm.severity {
        case .integrity:
            persistentAlert = text
        case .notice:
            lastError = text
        }
    }

    /// A message with the camera or device it came from in front of it.
    ///
    /// Deliberately NOT a localized format string, and the exception proves the
    /// i18n rule rather than bending it: there is no English here to translate.
    /// The source is a channel letter or a board's own name — data — and the
    /// message arrives already in the operator's language. A `"%@: %@"` key
    /// would be a row in both .strings files that no translator could act on.
    ///
    /// It is a function anyway because two callers do this — the alarm path
    /// above and the multicam start failure — and a separator that drifts
    /// between them is the kind of difference nobody notices until a bug report
    /// arrives with one of each in it.
    static func tagged(_ message: String, source: String?) -> String {
        source.map { "\($0): \(message)" } ?? message
    }

    // MARK: - free space

    /// Free-space watch on the record volume: warn early, stop the take
    /// before the writer hits a hard wall (nothing watched disk space at all).
    func startDiskWatch() {
        Task { [weak self] in
            while let self, !Task.isCancelled {
                self.checkDiskSpace()
                // Ten seconds idle, two while a take rolls: at UHD ProRes the
                // 0.5 GB floor lasts under six seconds, so a ten-second tick
                // let the writer hit ENOSPC between two looks.
                let interval = self.isRecording ? Self.diskWatchRecordingInterval
                                                : Self.diskWatchIdleInterval
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    static let diskWatchIdleInterval: Double = 10
    static let diskWatchRecordingInterval: Double = 2

    /// The open take's size at the last tick, and when — what the write rate
    /// is measured from. Measured rather than tabulated: a table of codec
    /// rates would be wrong for a second channel on the same volume, and the
    /// file's own growth is not.
    private struct TakeGrowth {
        var bytes: Int64
        var at: Date
    }
    private static var lastGrowth: TakeGrowth?

    /// Bytes per second the open take is growing at, from two looks at its
    /// size; nil until there have been two, or when nothing is open.
    func measuredWriteRate() -> Double? {
        guard isRecording, let name = pipeline.health.takeFileName else {
            Self.lastGrowth = nil
            return nil
        }
        let url = destinationRoot.appendingPathComponent(name)
        guard let size = (try? FileManager.default.attributesOfItem(
            atPath: url.path))?[.size] as? Int64 else { return nil }
        let now = Date()
        defer { Self.lastGrowth = TakeGrowth(bytes: size, at: now) }
        guard let last = Self.lastGrowth else { return nil }
        let seconds = now.timeIntervalSince(last.at)
        guard seconds > 0.5, size >= last.bytes else { return nil }
        return Double(size - last.bytes) / seconds
    }
    /// One tick of the watch above. Internal rather than private so the suite can
    /// drive exactly one, instead of waiting out a ten-second timer — which is a
    /// wall-clock window, and the one thing a wait in this repo may not be.
    func checkDiskSpace() {
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
                pipeline.stopRecordingIfRolling()
                persistentAlert = L("alarm_volume_unreachable")
            } else {
                persistentAlert = L("alarm_folder_unreachable",
                                    destinationRoot.path)
            }
            return
        }
        // These four assign the sticky register directly, so unlike a pipeline
        // alarm their severity was never inferred from the words and nothing
        // here had to change but the words themselves. The watchdog is the app's
        // own: it watches a volume, which is not something CaptureCore knows
        // about, so there is no boundary to carry a severity across.
        switch Self.diskVerdict(freeBytes: free, isRecording: isRecording,
                                bytesPerSecond: measuredWriteRate()) {
        case .fine:
            break
        case .full(let freeGB):
            // Close it while it can still finalize — a STOP and not a toggle:
            // `isRecording` is the main actor's mirror and the pipeline may have
            // closed the take already (see `stopRecordingIfRolling`).
            pipeline.stopRecordingIfRolling()
            persistentAlert = L("alarm_disk_full", freeGB)
        case .low(let freeGB):
            persistentAlert = L("alarm_disk_low", freeGB)
        }
    }

    /// What a free-space reading means, as a value.
    ///
    /// Split from the watchdog that acts on it for the same reason
    /// `bitDepthNotice` is split from `reportBitDepth`: the two halves fail
    /// differently. This one is a rule about two thresholds and can be stated
    /// exactly; the caller's half is about a volume that may not answer the
    /// question at all, and only a real disk can put it in either of these
    /// states. The thresholds ARE the recording-integrity promise — warn
    /// under 5 GB, close the take under 0.5 — so they belong somewhere that can
    /// be read and checked rather than inline in a tick nothing can drive.
    enum DiskVerdict: Equatable {
        /// Room to keep recording.
        case fine
        /// Under 5 GB: say so, and leave the take alone.
        case low(gigabytes: Double)
        /// Under 0.5 GB with a take rolling: close it while it still can
        /// finalize. Only ever while recording — an idle app on a nearly full
        /// disk gets the warning, not an intervention.
        case full(gigabytes: Double)
    }

    ///
    /// **The close threshold follows the write rate.** 0.5 GB was a fixed
    /// floor, and at UHD ProRes HQ (~88 MB/s) it lasts under six seconds — less
    /// than one ten-second tick, so the writer hit ENOSPC first and the take
    /// died as a writer failure, renamed `_FAILED`, instead of being closed
    /// while it could still finalize. With a measured rate the take is closed
    /// when what is left would not carry it through two more looks plus the
    /// floor; without one (the first tick of a take) the floor stands alone.
    static func diskVerdict(freeBytes: Int64, isRecording: Bool,
                            bytesPerSecond: Double? = nil) -> DiskVerdict {
        let freeGB = Double(freeBytes) / 1_000_000_000
        if isRecording {
            let floor = 0.5 * 1_000_000_000
            let runway = (bytesPerSecond ?? 0) * diskWatchRecordingInterval * 2
            if Double(freeBytes) < floor + runway { return .full(gigabytes: freeGB) }
        }
        return freeGB < 5 ? .low(gigabytes: freeGB) : .fine
    }
}
