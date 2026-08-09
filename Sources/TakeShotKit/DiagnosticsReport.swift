import Foundation

/// The bundle's `report.txt`: the whole snapshot as something a person reads.
///
/// English, not localized, unlike the menu item that produces it. The report is
/// written to be read later — by the owner, or by whoever he forwards it to —
/// and the same argument that keeps `CaptureCore`'s errors in English applies
/// with more force to a file whose whole purpose is to be sent somewhere.
///
/// The header comes first and says what is in the bundle and what is not,
/// because the decision to send it is one the owner has to make with the facts
/// in front of him, not after the fact.
enum DiagnosticsReport {
    /// Label column width. Wide enough for the longest label below, so every
    /// value in the file lines up in one column and can be skimmed.
    static let labelWidth = 24

    static func text(for snapshot: DiagnosticsSnapshot) -> String {
        var out: [String] = []
        out += header(snapshot)
        out += machine(snapshot)
        out += deckLink(snapshot)
        out += capture(snapshot)
        out += DiagnosticsStateReport.recording(snapshot)
        out += DiagnosticsStateReport.takes(snapshot)
        out += DiagnosticsStateReport.jobs(snapshot)
        out += DiagnosticsStateReport.remote(snapshot)
        out += DiagnosticsStateReport.settings(snapshot)
        out += DiagnosticsStateReport.windows(snapshot)
        return out.joined(separator: "\n") + "\n"
    }

    // MARK: - building blocks

    static func section(_ title: String) -> [String] {
        ["", title, String(repeating: "-", count: title.count), ""]
    }

    static func pair(_ label: String, _ value: String?) -> String {
        let padded = label.padding(toLength: max(labelWidth, label.count),
                                   withPad: " ", startingAt: 0)
        return "  \(padded)\(value ?? "—")"
    }

    static func pair(_ label: String, _ value: Bool) -> String {
        pair(label, value ? "yes" : "no")
    }

    static func pair(_ label: String, _ value: Int) -> String {
        pair(label, String(value))
    }

    /// Timestamps everywhere in the bundle, in one format: local wall clock
    /// with the offset, because "when did this happen" is asked against a call
    /// sheet, not against UTC.
    static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    // MARK: - sections

    private static func header(_ snapshot: DiagnosticsSnapshot) -> [String] {
        let title = "TAKESHOT DIAGNOSTIC BUNDLE"
        var out = [title, String(repeating: "=", count: title.count), ""]
        out.append(pair("Collected", stamp.string(from: snapshot.generatedAt)))
        out.append(pair("App", "TakeShot \(snapshot.app.version) "
                        + "(build \(snapshot.app.build))"))
        out.append(pair("Git commit", snapshot.app.gitSHA
                        ?? "unavailable (not a bundled build)"))
        out.append(pair("Bundle ID", snapshot.app.bundleIdentifier))
        out.append(pair("Running from", snapshot.app.bundlePath))
        out.append(pair("UI language", snapshot.app.language))
        out.append(pair("Demo source selected", snapshot.app.demoSourceSelected))
        out += contents()
        return out
    }

    /// The disclosure. Kept as literal prose rather than assembled from the
    /// snapshot: it is a promise about the code, and a promise that describes
    /// itself from the data it is describing is worth nothing.
    private static func contents() -> [String] {
        section("WHAT IS IN THIS BUNDLE") + [
            "  report.txt         this file",
            "  diagnostics.json   the same data, machine readable",
            "  log.txt            this app's own log output for the last hour",
            "",
            "  NOT in it, deliberately:",
            "    * The web remote's PIN. It is never written to any file here.",
            "    * Any footage, audio, still or thumbnail. Takes are listed by",
            "      name, length and size; nothing is copied out of the folder.",
            "    * Your account name, your machine's name, and any network",
            "      address. Paths are written with the home folder as \"~\".",
            "    * A screenshot. Capturing the screen needs macOS Screen",
            "      Recording consent, and a diagnostic must not put a",
            "      permission dialog in front of you mid-take — the app's own",
            "      open windows are listed at the end instead.",
            "    Nothing was uploaded. The app has no telemetry and made no",
            "    network request to produce this; it only wrote these files.",
            "",
            "  IN it, and it names the job:",
            "    the project name, scene and shot, roll, the take file names,",
            "    and the record folder. Read this file before sending it on if",
            "    the production is not public yet.",
        ]
    }

    private static func machine(_ snapshot: DiagnosticsSnapshot) -> [String] {
        let machine = snapshot.machine
        return section("MACHINE") + [
            pair("macOS", machine.osVersion),
            pair("Model", machine.model),
            pair("Architecture", machine.architecture),
            pair("Memory", String(format: "%.0f GB", machine.physicalMemoryGB)),
            pair("Cores", machine.processorCount),
            pair("Thermal state", machine.thermalState),
            pair("Low power mode", machine.lowPowerMode),
        ]
    }

    private static func deckLink(_ snapshot: DiagnosticsSnapshot) -> [String] {
        let deck = snapshot.deckLink
        var out = section("DECKLINK / CAPTURE HARDWARE") + [
            pair("Compiled with SDK", deck.compiledWithSDK),
            pair("Runtime loaded", deck.runtimeLoaded),
            pair("Framework on disk", deck.frameworkPresent),
            pair("Desktop Video", deck.desktopVideoVersion ?? "not installed"),
            pair("BRAW SDK", deck.brawSDKAvailable),
            pair("Diagnosis", deck.diagnosis.rawValue),
        ]
        out.append("")
        out += wrapped(deck.diagnosisText)
        out.append("")
        out.append(pair("Devices", deck.devices.isEmpty
                        ? "none" : String(deck.devices.count)))
        for device in deck.devices {
            out.append("    \(device.name)  [\(device.id)]")
        }
        out.append(pair("Selected device", deck.selectedDeviceID
                        ?? "none selected"))
        out.append(pair("Forced input mode", deck.forcedInputMode
                        ?? "autodetect"))
        return out
    }

    private static func capture(_ snapshot: DiagnosticsSnapshot) -> [String] {
        let capture = snapshot.capture
        var out = section("SIGNAL") + [
            pair("Capturing", capture.isCapturing),
            pair("Signal present", capture.signalPresent),
        ]
        if let name = capture.formatName {
            out.append(pair("Detected format", name))
            out.append(pair("Raster", "\(capture.width)x\(capture.height)"))
            out.append(pair("Frame rate",
                            String(format: "%.3f", capture.frameRate)))
            out.append(pair("Timecode rate", "\(capture.timecodeFPS) fps"
                            + (capture.isDropFrame ? " drop-frame" : "")))
            out.append(pair("RGB 4:4:4", capture.isRGB444))
            // The two depths, on adjacent lines and each labelled with whose
            // answer it is: the signal's, then what the board could be opened
            // with. They agree in the ordinary case and the difference is the
            // whole story in the interesting one.
            out.append(pair("Source bit depth", capture.sourceBitDepth
                            .map { "\($0)-bit" } ?? "not reported by the board"))
            out.append(pair("Wire bit depth", "\(capture.wireBitDepth)-bit"))
        } else {
            out.append(pair("Detected format", "none — no signal detected"))
        }
        out.append(pair("Timecode", capture.currentTimecode ?? "none"))
        out.append(pair("Levels setting", capture.levelsSetting))
        out.append(pair("Levels in effect", capture.levelsEffective))
        out.append(pair("HDR setting", capture.hdrSetting))
        out.append(pair("HDR signal", capture.hdrSignal))
        if !capture.hdrDisplayMetadata.isEmpty {
            out.append(pair("HDR displayMetadata", capture.hdrDisplayMetadata))
        }
        out.append(pair("Detection mode", capture.detectionMode))
        out.append(pair("Pre-roll", "\(capture.preRollFrames) frames"))
        // The third trigger — a switch orthogonal to the mode above, so it is
        // reported whatever that mode says.
        out.append(pair("REC indicator", capture.visualRec))
        return out
    }

    /// Break a long explanation onto lines that fit a terminal, indented under
    /// the value column.
    static func wrapped(_ text: String, width: Int = 72) -> [String] {
        var lines: [String] = []
        var current = "   "
        for word in text.split(separator: " ") {
            if current.count + word.count + 1 > width, current != "   " {
                lines.append(current)
                current = "   "
            }
            current += " \(word)"
        }
        if current != "   " { lines.append(current) }
        return lines
    }
}
