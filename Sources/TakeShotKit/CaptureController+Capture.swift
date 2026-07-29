import AVFoundation
import AppKit
import CaptureCore
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import SwiftUI
import os.log

/// Running the capture: devices, start/stop, the pipeline bindings, the disk
/// watchdog and the multicam channels.
///
/// Split out of CaptureController: the type had grown past 2600 lines, the
/// size at which nobody reads it top to bottom any more.
extension CaptureController {
    var backendAvailable: Bool { backend.isAvailable }

    /// Whether the demo source is selected (to show the "REC demo camera" button).
    var isMockSelected: Bool {
        selectedDeviceID?.hasPrefix("mock:") ?? false
    }

    /// Input mode names of the selected DeckLink (for the Settings picker).
    var selectedDeviceInputModes: [String] {
        guard let id = selectedDeviceID, id.hasPrefix("decklink:") else { return [] }
        return DeckLinkBackendAdapter.inputModeNames(
            deviceID: String(id.dropFirst("decklink:".count)))
    }

    /// All cameras for the preview grid: main (nil channel) + extras.
    var allCameraLabels: [String] {
        [settings.cameraLabel] + extraChannels.map(\.camLabel)
    }

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
            if let start = take.startTimecode,
               let tc = Timecode(text: marker.timecodeText, fps: start.fps) {
                var frames = tc.frameNumber - start.frameNumber
                if frames < 0 {
                    frames += Timecode.dayFrames(fps: start.fps,
                                                 isDropFrame: start.isDropFrame)
                }
                fixed.seconds = Double(frames) / Double(max(1, start.fps))
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
    private func reportPipelineError(_ message: String) {
        let sticky = ["TAKE LOST", "Dropped", "ingress",
                      "Failed to start recording", "Take closed:",
                      "Pre-roll incomplete"]
        if sticky.contains(where: message.contains) {
            persistentAlert = message
        } else {
            lastError = message
        }
    }
    func pushConfig() {
        pipeline.update(config: .init(
            settings: settings, roll: roll, takeNumber: nextTakeNumber))
        pipeline.setVideoLevels(settings.videoLevels)
        for channel in extraChannels {
            channel.update(settings: settings, roll: roll, takeNumber: nextTakeNumber)
        }
    }
    func toggleMulticam() {
        setMulticam(!multicamOn)
    }
    func setMulticam(_ on: Bool) {
        for channel in extraChannels { channel.stop() }
        extraChannels.removeAll()
        multicamOn = on
        guard on else { return }

        let nextLetter = FieldStepper.stepLetter(settings.cameraLabel, by: 1)
        if isMockSelected {
            // demo: a second mock camera
            let mock = MockCaptureBackend()
            let channel = CameraChannel(
                camLabel: nextLetter, backend: mock,
                deviceID: MockCaptureBackend.deviceID, settings: settings, roll: roll)
            channel.onTakeFinished = { [weak self] take in self?.appendChannelTake(take) }
            channel.onError = { [weak self] message in self?.reportPipelineError(message) }
            try? channel.start() // the mock cannot fail
            extraChannels = [channel]
        } else {
            // hardware: each OTHER DeckLink board is its own channel
            let others = devices.filter {
                $0.id.hasPrefix("decklink:") && $0.id != selectedDeviceID
            }
            var channels: [CameraChannel] = []
            var letter = nextLetter
            for device in others {
                let rawID = String(device.id.dropFirst("decklink:".count))
                let channel = CameraChannel(
                    camLabel: letter,
                    backend: DeckLinkBackendAdapter(watchesDevices: false),
                    deviceID: rawID, settings: settings, roll: roll)
                channel.onTakeFinished = { [weak self] take in self?.appendChannelTake(take) }
                channel.onError = { [weak self] message in self?.reportPipelineError(message) }
                do {
                    try channel.start()
                    channels.append(channel)
                } catch {
                    lastError = "\(device.name): \(error.localizedDescription)"
                }
                letter = FieldStepper.stepLetter(letter, by: 1)
            }
            extraChannels = channels
        }
    }
    private func appendChannelTake(_ take: Take) {
        takes.append(take)
        takes.sort { $0.recordedAt < $1.recordedAt }
        exportTakeLog()
        requestThumbnail(for: take)
    }
    func refreshDevices() {
        devices = backend.devices()

        let realDevices = devices.filter { !$0.id.hasPrefix("mock:") }
        if let selected = selectedDeviceID, !devices.contains(where: { $0.id == selected }) {
            // the selected device was unplugged — fall back to the first available
            selectedDeviceID = devices.first?.id
            // after the switch, not before it: assigning the device restarts
            // capture from its didSet, and a successful start clears lastError,
            // so setting the notice first meant unplugging a board while another
            // one was attached went by in silence.
            lastError = L("device_disconnected")
        } else if selectedDeviceID == nil || (isMockSelected && !realDevices.isEmpty) {
            // nothing selected, or the demo source is selected but a real board
            // appeared — switch to it (capture starts itself via didSet)
            selectedDeviceID = realDevices.first?.id ?? devices.first?.id
        }
    }
    func startCapture() {
        guard let deviceID = selectedDeviceID else { return }
        if let adapter = backend.child(of: DeckLinkBackendAdapter.self) {
            adapter.forcedMode = settings.forcedInputMode.map {
                (name: $0, rgb: settings.forcedInputRGB ?? false)
            }
            adapter.preferTenBitRGB = settings.tenBitCapture ?? true
        }
        do {
            try backend.startCapture(deviceID: deviceID)
            // before any audio packet, so a take triggered on frame 1 still gets
            // an audio track
            pipeline.setExpectedAudioChannels(backend.embeddedAudioChannels)
            isCapturing = true
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }
    func stopCapture() {
        backend.stopCapture()
        pipeline.captureStopped()
        isCapturing = false
        // await finishing the files in the background (without blocking the UI)
        Task { await pipeline.finishPendingWrites() }
    }
    /// A blocking flush on app exit — so the file isn't truncated.
    /// Closes the ACTIVE take too (quitting mid-record used to leave a .mov
    /// without its moov atom), and waits on a detached task: a MainActor task
    /// can never run while the main thread is parked in semaphore.wait.
    func flushOnTerminate() {
        pipeline.captureStopped() // finishes the in-flight take, if any
        for channel in extraChannels { channel.stopStreams() }
        let sem = DispatchSemaphore(value: 0)
        let pipeline = self.pipeline
        // EVERY pipeline must finalize before exit — the extra channels used
        // to fire-and-forget, leaving B/C-cam takes without moov atoms
        let channelPipelines = extraChannels.map(\.pipeline)
        Task.detached {
            await pipeline.finishPendingWrites()
            for channelPipeline in channelPipelines {
                await channelPipeline.finishPendingWrites()
            }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 15)
    }
    func restartCapture() {
        if isCapturing {
            stopCapture()
        }
        startCapture()
    }
    func toggleManualRecord() {
        pipeline.toggleManualRecord()
    }
}

// MARK: - CaptureBackendDelegate (callbacks from capture threads — straight into the pipeline)

extension CaptureController: CaptureBackendDelegate {
    nonisolated func backend(_ backend: CaptureBackend, didDetectFormat format: CaptureFormat) {
        pipeline.handleFormat(format)
    }

    nonisolated func backend(_ backend: CaptureBackend, didReceive frame: CapturedFrame) {
        pipeline.handleFrame(frame)
    }

    nonisolated func backend(_ backend: CaptureBackend, didReceiveAudio sampleBuffer: CMSampleBuffer) {
        pipeline.handleAudio(sampleBuffer)
    }

    nonisolated func backend(_ backend: CaptureBackend, signalPresent: Bool) {
        pipeline.handleSignal(present: signalPresent)
    }

    nonisolated func backendDeviceListChanged(_ backend: CaptureBackend) {
        Task { @MainActor in
            self.refreshDevices()
        }
    }
}
