import CaptureCore
import Foundation

/// What the phone shows, and the four commands it can send back.
///
/// Split out of `+Remote`, which brings the server up and down. The status is
/// built on the MainActor and handed over as a value — the server never reads
/// controller state — and every command lands on the method the on-screen
/// button calls, so there is no second path to the recorder.
extension CaptureController {
    // MARK: - status

    /// What the phone shows. Built here on the MainActor and handed over as a
    /// value — the server never reads controller state.
    func remoteStatus() -> RemoteStatus {
        var status = RemoteStatus()
        status.timecode = live.currentTimecode?.description ?? ""
        status.recording = isRecording
        status.capturing = isCapturing
        status.format = signalFormat?.name ?? ""
        // While a take rolls, the name being written is the pending one — the
        // same string the collision warning is about. Afterwards it is the take
        // that just landed, which is also the one the ratings apply to.
        status.takeName = isRecording
            ? pendingTakeName : (takes.last?.displayName ?? "")
        status.rating = (takes.last?.rating ?? .none).rawValue
        status.diskFreeGB = remoteDiskFreeGB
        status.markerCount = isRecording
            ? recordingMarkers.count : (takes.last?.markers.count ?? 0)
        return status
    }

    /// Push the status now rather than at the next tick — a button that lights
    /// up a quarter of a second late reads as a dropped press.
    func pushRemoteStatus() {
        remoteServer?.broadcast(remoteStatus())
    }

    func startRemoteStatusPump() {
        remoteStatusTask?.cancel()
        remoteStatusTask = Task { [weak self] in
            var ticks = 0
            var lastSent: RemoteStatus?
            while !Task.isCancelled {
                guard let self else { return }
                if ticks % Self.remoteDiskTicks == 0 { self.sampleRemoteDisk() }
                let status = self.remoteStatus()
                if status != lastSent || ticks % Self.remoteHeartbeatTicks == 0 {
                    self.remoteServer?.broadcast(status)
                    lastSent = status
                }
                ticks &+= 1
                try? await Task.sleep(for: Self.remoteTick)
            }
        }
    }

    private func sampleRemoteDisk() {
        let values = try? destinationRoot.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let free = values?.volumeAvailableCapacityForImportantUsage else {
            // The volume is gone. -1 shows as a dash on the phone rather than
            // as a confident 0.0 GB.
            remoteDiskFreeGB = -1
            return
        }
        remoteDiskFreeGB = Double(free) / 1_000_000_000
    }

    // MARK: - commands

    /// One command from a phone, on the MainActor.
    func perform(remote command: RemoteCommand) {
        switch command {
        case .hello:
            break // the PIN handshake; the server has already answered it
        case .rec:
            // The same guard the on-screen button carries: with no capture
            // running there is nothing to record, and the pipeline would take
            // the press and sit on it.
            guard isCapturing else { return }
            toggleManualRecord()
        case .marker:
            addMarker()
        case .good:
            toggleLastRating(.good)
        case .bad:
            toggleLastRating(.bad)
        }
        pushRemoteStatus()
    }
}
