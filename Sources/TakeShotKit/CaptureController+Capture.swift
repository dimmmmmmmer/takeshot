import CaptureCore
import Foundation

/// Running the capture: which device, starting it, stopping it, and getting the
/// files closed on the way out.
///
/// Split out of CaptureController: the type had grown past 2600 lines, the
/// size at which nobody reads it top to bottom any more. What the pipeline
/// reports back — and the disk watchdog that reports on its own — is
/// `+CaptureEvents`; the extra boards are `+Multicam`.
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

    /// The operator picked a different board. Capture restarts itself from the
    /// observer rather than from a button — there is no separate start control.
    func applySelectedDevice(from oldValue: String?) {
        guard oldValue != selectedDeviceID else { return }
        restartCapture()
    }

    func pushConfig() {
        pipeline.update(config: .init(
            settings: settings, roll: roll, takeNumber: nextTakeNumber))
        pipeline.setVideoLevels(settings.videoLevels)
        for channel in extraChannels {
            channel.update(settings: settings, roll: roll, takeNumber: nextTakeNumber)
        }
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
    func restartCapture() {
        if isCapturing {
            stopCapture()
        }
        startCapture()
    }
    func toggleManualRecord() {
        pipeline.toggleManualRecord()
    }
    /// A blocking flush on app exit — so the file isn't truncated.
    /// Closes the ACTIVE take too (quitting mid-record used to leave a .mov
    /// without its moov atom), and waits on a detached task: a MainActor task
    /// can never run while the main thread is parked in semaphore.wait.
    func flushOnTerminate() {
        // Before anything blocks: the remote's listener and its clients have to
        // go, or a phone holds a socket open against a process that is parked in
        // a semaphore waiting for the writer.
        stopRemoteServer()
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
        let flushed = sem.wait(timeout: .now() + 15)

        // The files are safe now, but each finalize task published its take
        // with a main-queue hop this parked thread has not serviced — quitting
        // here kept the .mov and lost its list entry, its log row and its
        // metadata. Pump the run loop until a sentinel enqueued BEHIND those
        // publications runs (the main queue is FIFO), then let the log queue
        // drain the CSV write the publications scheduled. Skipped when the
        // flush itself timed out: a writer still stuck after 15 s has
        // published nothing to wait for.
        guard flushed == .success else { return }
        let sentinel = DispatchSemaphore(value: 0)
        DispatchQueue.main.async { sentinel.signal() }
        let deadline = Date().addingTimeInterval(2)
        while sentinel.wait(timeout: .now()) != .success, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        Self.takeLogQueue.sync {}
    }
}

// MARK: - CaptureBackendDelegate (callbacks from capture threads — straight into the pipeline)

/// The four per-frame callbacks are the shared ones (see
/// `PipelineBackendDelegate`); only the main camera acts on the device list.
extension CaptureController: PipelineBackendDelegate {
    nonisolated func backendDeviceListChanged(_ backend: CaptureBackend) {
        Task { @MainActor in
            self.refreshDevices()
        }
    }
}
