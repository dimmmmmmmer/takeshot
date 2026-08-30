import AppKit
import CaptureCore
import Foundation

/// The rest of the diagnostic snapshot: the recorder, the takes, the disk
/// jobs, the remote and the open windows.
///
/// Split from `+Diagnostics` for the reason the controller's other extensions
/// are — one file per subject, none of them long enough to stop being read.
/// Everything here is main-actor state read synchronously; nothing blocks.
extension CaptureController {
    // MARK: - the recorder

    func diagnosticsRecording() -> DiagnosticsSnapshot.RecordingSection {
        var recording = DiagnosticsSnapshot.RecordingSection()
        let root = destinationRoot
        recording.recordFolder = DiagnosticsRedaction.abbreviate(root)
        recording.recordFolderExists =
            FileManager.default.fileExists(atPath: root.path)
        recording.recordFolderWritable =
            FileManager.default.isWritableFile(atPath: root.path)
        let values = try? root.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                      .volumeNameKey])
        recording.volumeName = values?.volumeName
        // Left nil rather than 0 when the query fails: a volume that has gone
        // away is exactly how it fails, and "0 GB free" would send whoever
        // reads this after the wrong fault.
        recording.freeSpaceGB = values?.volumeAvailableCapacityForImportantUsage
            .map { Double($0) / 1_000_000_000 }
        recording.codec = settings.capture.codec.rawValue
        recording.health = pipeline.health
        recording.persistentAlert = persistentAlert
        recording.lastError = lastError
        recording.audioSource = externalAudioActive
            ? "external (USB input device)" : "embedded (capture board)"
        recording.externalAudioActive = externalAudioActive
        recording.audioChannelMask = effectiveAudioChannelMask
            .map { String(format: "0x%04X", $0) }
        recording.audioChannelDecision = Self.channelDecision(
            automatic: isAudioChannelsAutomatic,
            measured: detectedAudioChannelMask != nil)
        return recording
    }

    /// Who chose the channel mask, as the bundle words it.
    ///
    /// A pure function of the two flags rather than a chain inside the builder:
    /// the builder needs a live controller and a real pipeline to run at all,
    /// and the three answers are exactly the thing a reader of a bundle has to
    /// be able to trust. Three, not two — "auto and nothing measured yet"
    /// records every channel and is what the first seconds of every session
    /// look like (see `AudioChannelDetector`).
    static func channelDecision(automatic: Bool, measured: Bool) -> String {
        guard automatic else { return "operator" }
        return measured
            ? "auto — measured while standing by"
            : "auto — nothing measured carrying yet, so all channels"
    }

    // MARK: - the takes

    func diagnosticsTakes() -> DiagnosticsSnapshot.TakesSection {
        var section = DiagnosticsSnapshot.TakesSection()
        section.total = takes.count
        section.retired = retiredTakes.count
        let recent = takes.suffix(Self.diagnosticsTakeCount)
        section.listed = recent.count
        section.recent = recent.map(Self.diagnosticsRow(for:))
        return section
    }

    /// One take as the report lists it.
    ///
    /// The file is stat'd rather than trusted: a take in the list whose file is
    /// gone, or whose file is 0 bytes, is precisely the failure this bundle is
    /// collected over, and the list alone cannot say either.
    static func diagnosticsRow(for take: Take)
        -> DiagnosticsSnapshot.TakeRow {
        var row = DiagnosticsSnapshot.TakeRow()
        row.name = take.url.lastPathComponent
        row.recordedAt = take.recordedAt
        row.durationSeconds = take.durationSeconds
        row.roll = take.roll
        row.clip = take.takeNumber
        row.startTimecode = take.startTimecode?.description
        row.rating = take.rating.rawValue
        // The rename a failed finalize leaves behind (see
        // `CapturePipeline.markFailed`) — the file name IS the marker.
        // `contains`, not `hasSuffix`: a second failure on the same name comes
        // out as `..._FAILED_2.mov`.
        row.failedFinalize = take.url.deletingPathExtension()
            .lastPathComponent.contains(CapturePipeline.failedTakeSuffix)
        let attributes = try? FileManager.default
            .attributesOfItem(atPath: take.url.path)
        row.fileExists = attributes != nil
        row.fileSizeBytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        // The pipeline writes its own integrity note here (padded audio); an
        // operator's own comment lands in the same field and is disclosed as
        // production data at the top of the report.
        row.note = take.comment.isEmpty ? nil : take.comment
        return row
    }

    // MARK: - the long-running jobs

    func diagnosticsJobs() -> DiagnosticsSnapshot.JobsSection {
        var jobs = DiagnosticsSnapshot.JobsSection()
        jobs.offloadRunning = offload.isRunning
        jobs.offloadStatus = offloadStatus
        jobs.offloadSource = offload.source.map(DiagnosticsRedaction.abbreviate)
        jobs.offloadDestinations =
            offload.destinations.map(DiagnosticsRedaction.abbreviate)
        jobs.verifyRunning = verify.isRunning
        jobs.verifyRoot = verify.root.map(DiagnosticsRedaction.abbreviate)
        jobs.dailiesRunning = dailies.isRunning
        jobs.dailiesStatus = dailiesStatus
        jobs.dailiesQueued = dailies.queuedTakes.count
        jobs.dailiesDestination =
            dailies.destination.map(DiagnosticsRedaction.abbreviate)
        return jobs
    }

    // MARK: - the web remote

    /// The remote, minus the one thing it must never give away.
    ///
    /// `pinConfigured` is a yes/no because "the phone says wrong code" has two
    /// causes — no PIN was ever generated, or the operator is typing the wrong
    /// one — and only the first is diagnosable without the digits. The digits
    /// have no field to go in (see `DiagnosticsSnapshot.RemoteSection`).
    func diagnosticsRemote() -> DiagnosticsSnapshot.RemoteSection {
        var remote = DiagnosticsSnapshot.RemoteSection()
        remote.enabled = settings.remote.enabled == true
        remote.boundPort = remoteBoundPort
        remote.configuredPort = settings.remote.portEffective
        remote.clientCount = remoteServer?.clientCount ?? 0
        // The composed grid, which is what the live page carries now that
        // the JPEG /cameras page is gone.
        remote.multiviewActive = mirrors.gridComposer != nil
        remote.pinConfigured = settings.remote.pin?.isEmpty == false
        return remote
    }

    // MARK: - the windows

    /// The app's own windows: which are open and where.
    ///
    /// Not a screenshot. `CGWindowListCreateImage` needs Screen Recording
    /// consent on every macOS since Catalina, and a diagnostic that raises a
    /// TCC dialog between takes is worse than one that omits a picture — so it
    /// omits the picture and the report says why. Titles are left out too: a
    /// title can carry a clip name, and the take list already covers that
    /// ground with the disclosure attached.
    func diagnosticsWindows() -> [DiagnosticsSnapshot.WindowRow] {
        NSApplication.shared.windows.map { window in
            DiagnosticsSnapshot.WindowRow(
                identifier: window.identifier?.rawValue
                    ?? String(describing: type(of: window)),
                frame: String(format: "%.0f,%.0f %.0fx%.0f",
                              window.frame.origin.x, window.frame.origin.y,
                              window.frame.width, window.frame.height),
                visible: window.isVisible)
        }
    }
}

/// The machine, from `sysctl` and `ProcessInfo`.
///
/// Deliberately narrow. The model identifier, the OS and the thermal state say
/// why a rig drops frames; the machine's NAME and the logged-in user say who
/// owns it, and neither is collected. There is no host name in this bundle.
enum DiagnosticsMachine {
    static func current() -> DiagnosticsSnapshot.MachineSection {
        let info = ProcessInfo.processInfo
        var machine = DiagnosticsSnapshot.MachineSection()
        machine.osVersion = info.operatingSystemVersionString
        machine.model = sysctl("hw.model") ?? "unknown"
        machine.architecture = sysctl("hw.machine") ?? "unknown"
        machine.physicalMemoryGB =
            Double(info.physicalMemory) / 1_073_741_824
        machine.processorCount = info.processorCount
        machine.thermalState = label(for: info.thermalState)
        machine.lowPowerMode = info.isLowPowerModeEnabled
        return machine
    }

    /// A string `sysctl` value, sized then read. Nil rather than a guess when
    /// the key is not there — a made-up model number is worse than none.
    private static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0
        else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        // Through the pointer rather than the array: Swift 6 deprecates the
        // array overload of `String(cString:)`, and sysctl reports a length
        // that includes the terminator it wrote.
        return buffer.withUnsafeBufferPointer {
            $0.baseAddress.map { String(cString: $0) }
        }
    }

    private static func label(for state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious — the machine is throttling"
        case .critical: return "critical — the machine is throttling hard"
        @unknown default: return "unknown"
        }
    }
}
