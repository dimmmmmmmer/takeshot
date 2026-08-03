import AppKit
import CBraw
import CDeckLink
import CaptureCore
import Foundation

/// "Collect diagnostics": one menu item, one folder on the Desktop, no
/// questions asked.
///
/// The rule this feature is built to is that it must work when everything else
/// does not — no board attached, no signal, no record folder configured, an
/// alarm up — and that it must be safe to press while a take is rolling. So:
///
/// * Nothing here touches the writer, and nothing hops onto the capture queue.
///   The pipeline's counters are read through `pipeline.health`, a lock-guarded
///   mirror that exists precisely so this can be answered without a `queue.sync`
///   (see `CapturePipeline+Health`).
/// * Every value is read on the main actor in one synchronous pass, into a
///   `Sendable` snapshot. The log query and the file writes then happen on a
///   background task, so a slow disk cannot stutter a recording UI.
/// * Every section is written to survive its subject being absent. "No device
///   attached" is a line in the report, not a reason for it not to exist.
extension CaptureController {
    /// How many takes the report lists. The whole day would make the file
    /// unreadable and the take log beside the footage already has all of them;
    /// what a fault needs is the run-up to it.
    static let diagnosticsTakeCount = 20

    /// Collect the bundle and reveal it.
    ///
    /// `parent` is the seam the tests use: nothing in the suite may write to
    /// the operator's Desktop, and nothing in the app passes it.
    func collectDiagnostics(into parent: URL? = nil) {
        let snapshot = diagnosticsSnapshot()
        let parents = parent.map { [$0] } ?? DiagnosticsBundle.defaultParents()
        Task { [weak self] in
            let outcome = await DiagnosticsBundle.produce(snapshot, in: parents)
            guard let self else { return }
            switch outcome {
            case .written(let url):
                self.lastNotice = L("diagnostics_saved", url.lastPathComponent)
                FinderOpen.folder(url)
            case .failed(let reason):
                self.lastError = L("diagnostics_failed", reason)
            }
        }
    }

    /// Everything the bundle says, taken in one pass.
    func diagnosticsSnapshot() -> DiagnosticsSnapshot {
        var snapshot = DiagnosticsSnapshot()
        snapshot.app = diagnosticsApp()
        snapshot.machine = DiagnosticsMachine.current()
        snapshot.deckLink = diagnosticsDeckLink()
        snapshot.capture = diagnosticsCapture()
        snapshot.recording = diagnosticsRecording()
        snapshot.takes = diagnosticsTakes()
        snapshot.jobs = diagnosticsJobs()
        snapshot.remote = diagnosticsRemote()
        snapshot.settings = DiagnosticsRedaction.settings(settings)
        snapshot.windows = diagnosticsWindows()
        return snapshot
    }

    // MARK: - the app itself

    private func diagnosticsApp() -> DiagnosticsSnapshot.AppSection {
        var app = DiagnosticsSnapshot.AppSection()
        let info = Bundle.main.infoDictionary
        app.version = info?["CFBundleShortVersionString"] as? String ?? "dev"
        app.build = info?["CFBundleVersion"] as? String ?? "-"
        // Stamped by scripts/bundle-app.sh. An unbundled `swift run` has no
        // Info.plist of its own, so nil here means "not a packaged build",
        // which is itself the answer to "which build is this".
        app.gitSHA = info?[Self.gitSHAInfoKey] as? String
        app.bundleIdentifier = Bundle.main.bundleIdentifier
        app.bundlePath = DiagnosticsRedaction.abbreviate(Bundle.main.bundleURL)
        app.language = L10n.current.rawValue
        app.demoSourceSelected = isMockSelected
        return app
    }

    /// Info.plist key `scripts/bundle-app.sh` writes the short commit into.
    static let gitSHAInfoKey = "TakeShotGitSHA"

    // MARK: - the DeckLink situation

    private func diagnosticsDeckLink() -> DiagnosticsSnapshot.DeckLinkSection {
        var deck = DiagnosticsSnapshot.DeckLinkSection()
        deck.compiledWithSDK = CDLDeviceManager.isCompiledWithSDK()
        deck.runtimeLoaded = CDLDeviceManager.isSDKAvailable()
        deck.frameworkPresent = DeckLinkProbe.frameworkPresent
        deck.desktopVideoVersion = DeckLinkProbe.desktopVideoVersion
        deck.diagnosis = .of(compiledWithSDK: deck.compiledWithSDK,
                             runtimeLoaded: deck.runtimeLoaded,
                             frameworkPresent: deck.frameworkPresent)
        deck.diagnosisText = deck.diagnosis.explanation
        // The AGGREGATE list, not the DeckLink bridge's: what the operator was
        // choosing from is what matters, and "only the demo source is here" is
        // a different fault from "the list is empty".
        deck.devices = devices.map {
            DiagnosticsSnapshot.DeviceRow(id: $0.id, name: $0.name)
        }
        deck.selectedDeviceID = selectedDeviceID
        deck.forcedInputMode = settings.forcedInputMode
        deck.brawSDKAvailable = CBRClip.isSDKAvailable()
        return deck
    }

    // MARK: - the signal

    private func diagnosticsCapture() -> DiagnosticsSnapshot.CaptureSection {
        var capture = DiagnosticsSnapshot.CaptureSection()
        capture.isCapturing = isCapturing
        capture.signalPresent = signalPresent
        if let format = signalFormat {
            capture.formatName = format.name
            capture.width = format.width
            capture.height = format.height
            capture.frameRate = format.frameRate
            capture.timecodeFPS = format.timecodeFPS
            capture.isDropFrame = format.isDropFrame
            capture.isRGB444 = format.isRGB444
            capture.wireBitDepth = format.bitDepth
        }
        capture.currentTimecode = currentTimecode?.description
        capture.levelsSetting = settings.videoLevels ?? "auto"
        capture.levelsEffective = diagnosticsLevelsInEffect()
        capture.tenBitCapture = settings.tenBitCapture ?? true
        capture.detectionMode = settings.detectionMode.rawValue
        capture.preRollFrames = settings.preRollFramesEffective
        return capture
    }

    /// What the levels stage is actually doing to this signal.
    ///
    /// The stored setting is not the answer: most rigs are on "auto", which
    /// resolves against whether the source is RGB 4:4:4, and an operator asking
    /// "why are the blacks washed" needs the resolved value, not the wish. The
    /// normalization mirrors `CapturePipeline.setVideoLevels` and
    /// `effectiveInputLevels` — the two legacy spellings included, because a
    /// settings blob written years ago still carries them.
    private func diagnosticsLevelsInEffect() -> String {
        let normalized: String?
        switch settings.videoLevels {
        case "auto", nil: normalized = nil
        case "off": normalized = InputLevels.full.rawValue
        case "limited_excursions": normalized = InputLevels.limited.rawValue
        case let stored: normalized = stored
        }
        // Auto with no format yet has not decided anything, and saying
        // "passthrough" here would be a claim about a frame that never arrived.
        guard let format = signalFormat else {
            return normalized.map(describe(levels:))
                ?? "undecided — auto, and no signal to decide against"
        }
        guard let resolved = normalized
                ?? (format.isRGB444 ? InputLevels.limited.rawValue : nil)
        else { return "passthrough — YUV source under auto, nothing expanded" }
        return describe(levels: resolved)
    }

    private func describe(levels: String) -> String {
        InputLevels.resolved(levels) == .limited
            ? "limited — studio swing expanded for the display"
            : "full — passed through"
    }
}
