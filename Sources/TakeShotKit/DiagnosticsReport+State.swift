import CaptureCore
import Foundation

/// The half of `report.txt` that is about what the app was DOING: the recorder
/// and its counters, the takes, the disk jobs, the remote, the settings blob
/// and the open windows.
///
/// Split from `DiagnosticsReport` for the reason every other type here is
/// split — the file was going to run past the length at which nobody reads it
/// top to bottom. The rendering helpers (`section`, `pair`) stay in one place.
enum DiagnosticsStateReport {
    private static func section(_ title: String) -> [String] {
        DiagnosticsReport.section(title)
    }

    private static func pair(_ label: String, _ value: String?) -> String {
        DiagnosticsReport.pair(label, value)
    }

    private static func pair(_ label: String, _ value: Bool) -> String {
        DiagnosticsReport.pair(label, value)
    }

    private static func pair(_ label: String, _ value: Int) -> String {
        DiagnosticsReport.pair(label, value)
    }

    // MARK: - the recorder

    static func recording(_ snapshot: DiagnosticsSnapshot) -> [String] {
        let recording = snapshot.recording
        var out = section("RECORDING") + [
            pair("Record folder", recording.recordFolder.isEmpty
                 ? "NOT CONFIGURED" : recording.recordFolder),
            pair("Folder exists", recording.recordFolderExists),
            pair("Folder writable", recording.recordFolderWritable),
            pair("Volume", recording.volumeName ?? "unreadable"),
            pair("Free space", recording.freeSpaceGB
                    .map { String(format: "%.1f GB", $0) }
                 ?? "unreadable — the volume may be gone"),
            pair("Codec", recording.codec),
            pair("Audio source", recording.audioSource),
            pair("External audio live", recording.externalAudioActive),
            pair("Audio channel mask", recording.audioChannelMask ?? "all"),
            pair("Audio channels chosen by",
                 recording.audioChannelDecision ?? "unrecorded"),
        ]
        out.append("")
        out += counters(recording.health)
        out.append("")
        out.append(pair("Sticky alarm", recording.persistentAlert
                        ?? "none — no integrity alarm is up"))
        out.append(pair("Last error toast", recording.lastError ?? "none"))
        return out
    }

    /// The drop counters, per take and since launch. Both, because either one
    /// alone lies: a take-local count hides a rig that drops two frames on
    /// every single take, and a session total hides which take was the bad one.
    /// Internal rather than private so the suite can read one line back
    /// without assembling a whole bundle.
    static func counters(_ health: PipelineHealth) -> [String] {
        [
            pair("Take rolling", health.isRecording),
            // What rolled it. The single line that turns "it started on its own"
            // into a question with an answer, and it survives the take closing
            // (see `PipelineHealth.startTrigger`) — which is when a bundle
            // usually gets collected.
            pair("Started by", health.startTrigger?.rawValue
                 ?? "nothing yet this session"),
            pair("Open take", health.takeFileName ?? "none"),
            pair("Dropped video frames", "\(health.droppedVideoFramesInTake) "
                 + "in this take, \(health.droppedVideoFramesTotal) since launch"),
            pair("Dropped audio packets", "\(health.droppedAudioPacketsInTake) "
                 + "in this take, \(health.droppedAudioPacketsTotal) since launch"),
            pair("Gap-filled audio", "\(health.gapFilledAudioPacketsInTake) "
                 + "in this take, \(health.gapFilledAudioPacketsTotal) since launch"),
            pair("Padded audio track", "\(health.paddedAudioPacketsInTake) "
                 + "in this take, \(health.paddedAudioPacketsTotal) since launch"),
            pair("Ingress drops", health.ingressDrops),
            pair("Chroma late drops", health.chromaLateDrops),
            // The recording half, which is the one that costs footage: a take
            // the operator believes was keyed with the green screen still in
            // it. It had been counted since the bake shipped and printed
            // nowhere.
            pair("Chroma bake fallbacks", health.chromaBakeFallbacks),
            pair("Takes closed", health.takesClosed),
            pair("Failed to finalize", health.takesFailedToFinalize),
        ]
    }

    // MARK: - the takes

    static func takes(_ snapshot: DiagnosticsSnapshot) -> [String] {
        let takes = snapshot.takes
        var out = section("TAKES") + [
            pair("In the list", takes.total),
            pair("Retired (file gone)", takes.retired),
            pair("Listed below", takes.listed),
        ]
        out.append("")
        guard !takes.recent.isEmpty else {
            out.append("  No takes this session.")
            return out
        }
        for take in takes.recent { out += row(take) }
        return out
    }

    private static func row(_ take: DiagnosticsSnapshot.TakeRow) -> [String] {
        var line = "  \(DiagnosticsReport.stamp.string(from: take.recordedAt))"
        line += String(format: "  %7.2fs  ", take.durationSeconds)
        line += take.name
        var out = [line]
        var facts = ["roll \(take.roll)", "clip \(take.clip)"]
        if let timecode = take.startTimecode { facts.append("TC \(timecode)") }
        if take.rating != "none" { facts.append(take.rating.uppercased()) }
        facts.append(take.fileExists
                     ? String(format: "%.1f MB",
                              Double(take.fileSizeBytes) / 1_000_000)
                     : "FILE MISSING")
        // The marker the finalize failure leaves behind. Spelled out rather
        // than left implicit in the file name, because that is the one line
        // somebody scanning this report is looking for.
        if take.failedFinalize { facts.append("FAILED FINALIZE") }
        out.append("      " + facts.joined(separator: "  |  "))
        if let note = take.note, !note.isEmpty {
            out.append("      note: \(note)")
        }
        return out
    }

    // MARK: - the long-running jobs

    static func jobs(_ snapshot: DiagnosticsSnapshot) -> [String] {
        let jobs = snapshot.jobs
        var out = section("JOBS") + [
            pair("Offload running", jobs.offloadRunning),
            pair("Offload status", jobs.offloadStatus ?? "idle"),
            pair("Offload source", jobs.offloadSource),
            pair("Offload targets", jobs.offloadDestinations.isEmpty
                 ? "none" : jobs.offloadDestinations.joined(separator: ", ")),
            pair("Verify running", jobs.verifyRunning),
            pair("Verify folder", jobs.verifyRoot),
            pair("Dailies running", jobs.dailiesRunning),
            pair("Dailies status", jobs.dailiesStatus ?? "idle"),
            pair("Dailies queued", jobs.dailiesQueued),
            pair("Dailies folder", jobs.dailiesDestination),
        ]
        out.append("")
        out.append("  A running offload, verify or dailies transcode holds the")
        out.append("  offload queue; only one disk job runs at a time.")
        return out
    }

    // MARK: - the web remote

    static func remote(_ snapshot: DiagnosticsSnapshot) -> [String] {
        let remote = snapshot.remote
        return section("WEB REMOTE") + [
            pair("Enabled", remote.enabled),
            pair("Configured port", remote.configuredPort),
            pair("Bound port", remote.boundPort == 0
                 ? "0 — not listening" : String(remote.boundPort)),
            pair("Connected clients", remote.clientCount),
            pair("Camera grid active", remote.multiviewActive),
            pair("PIN", remote.pinConfigured
                 ? "set (not included in this bundle)"
                 : "not set (not included in this bundle)"),
        ]
    }

    // MARK: - the settings blob

    static func settings(_ snapshot: DiagnosticsSnapshot) -> [String] {
        var out = section("SETTINGS")
        out.append("  Every stored preference except the redacted ones; paths")
        out.append("  are written with the home folder as \"~\".")
        out.append("")
        for key in snapshot.settings.keys.sorted() {
            out.append(pair(key, snapshot.settings[key]))
        }
        return out
    }

    // MARK: - the windows

    static func windows(_ snapshot: DiagnosticsSnapshot) -> [String] {
        var out = section("OPEN WINDOWS")
        out.append("  Identifier and geometry only — a window title can carry a")
        out.append("  clip name. No screenshot: that needs Screen Recording")
        out.append("  consent, which this must never ask for on a shooting day.")
        out.append("")
        guard !snapshot.windows.isEmpty else {
            out.append("  None.")
            return out
        }
        for window in snapshot.windows {
            out.append("  \(window.visible ? "visible" : "hidden ")  "
                       + "\(window.frame)  \(window.identifier)")
        }
        return out
    }
}
