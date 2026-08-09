import AVFoundation
import AppKit
import CaptureCore
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import SwiftUI
import os.log

/// What a settings change sets in motion, plus the appearance the settings
/// pane owns: theme, player backdrop, accent, and the resets.
///
/// Split out of CaptureController: the type had grown past 2600 lines, the
/// size at which nobody reads it top to bottom any more.
extension CaptureController {
    /// Every settings write lands here (from the `settings` didSet). Only the
    /// parts of the app the change actually touches are rebuilt — see below.
    func applySettingsChange(from oldValue: CaptureSettings) {
        settings.save(to: defaults)
        // A settings write fans out only to the subsystems the change actually
        // touches: a volume slider tick lands here too, and rebuilding the
        // world on every one of them is what made the sliders lag.
        applyLanguageChange(from: oldValue)
        applyPipelineChange(from: oldValue)
        applyDeviceChange(from: oldValue)
        applyAudioInputChange(from: oldValue)
        applyNamingChange(from: oldValue)
        applyRemoteChange(from: oldValue)
        applyNDIChange(from: oldValue)
        applyCardWatchChange(from: oldValue)
        applyMenuBarChange(from: oldValue)
        applyGuideChange()
        applyLegendChange()
    }

    /// The framelines and the safe areas are stored as settings but DRAWN with
    /// the operator aids (see `AssistGuides`), so a change to either has to
    /// reach `assist` — that is the value every surface and the playout are
    /// fed from. Guarded on a real difference: this runs on every settings
    /// write, volume slider ticks included, and `assist` is @Published.
    private func applyGuideChange() {
        let guides = AssistGuides(settings: settings.assist)
        guard guides != assist.guides else { return }
        setAssist { $0.guides = guides }
    }

    /// The exposure legend is stored the same way and drawn in the same place
    /// (see `AssistLegend`), so its size and edge take the same route to the
    /// renderer: a picker click reaches the hardware monitor because `assist`
    /// is what every surface is fed. Guarded on a real difference for the
    /// reason above — every settings write lands here.
    private func applyLegendChange() {
        var legend = AssistLegend(settings: settings.assist)
        // …plus the one thing about it that is not a setting: what the signal
        // is encoded with, which decides whether the two top bands are labelled
        // as percentages of an SDR scale or in cd/m² (see `AssistLegend`).
        legend.transfer = signalColorimetry.transfer
        guard legend != assist.legend else { return }
        setAssist { $0.legend = legend }
    }

    /// The signal changed what it says its codes mean: the legend's labels
    /// follow it. Called from the colorimetry callback, not from a settings
    /// write, and it goes through the same guarded path so a signal that was
    /// already SDR costs nothing.
    func applyColorimetryToLegend() {
        applyLegendChange()
    }

    /// Bundle lookups hit the disk — only on an actual language change.
    private func applyLanguageChange(from oldValue: CaptureSettings) {
        guard oldValue.theme.appLanguage != settings.theme.appLanguage else { return }
        L10n.apply(appLanguage)
    }

    /// The pipeline only needs a push when something it reads has changed; the
    /// monitoring level, the DIM and mute holds and the web remote are the
    /// fields it does not read — the holds are applied straight to the monitor
    /// and the remote is a socket, and rebuilding the capture config per dim or
    /// mute click (or per remote toggle) would make the sliders lag for nothing.
    private func applyPipelineChange(from oldValue: CaptureSettings) {
        var pipelineRelevant = oldValue
        // Two WHOLE groups the pipeline has never heard of. The remote is a
        // socket, and NDI is a display mirror wired outside the capture config
        // — flicking either switch, or typing in the NDI name field, must not
        // rebuild capture mid-take. Masking the group rather than its fields
        // one by one is also what keeps this honest when a field is added to
        // either: it stays out of the capture config by default, which is the
        // safe direction.
        pipelineRelevant.remote = settings.remote
        pipelineRelevant.ndi = settings.ndi
        // The rest are single fields whose NEIGHBOURS in the same group do
        // reach the pipeline, so these cannot be masked a group at a time.
        // The holds and the level are applied straight to the monitor, and
        // rebuilding the world per dim or mute click is what made the slider lag.
        pipelineRelevant.audio.monitorVolume = settings.audio.monitorVolume
        pipelineRelevant.audio.monitorDimmed = settings.audio.monitorDimmed
        pipelineRelevant.audio.monitorMuted = settings.audio.monitorMuted
        // the status item is a window-level affordance; the writer has never
        // heard of it, and toggling it must not rebuild the capture config
        pipelineRelevant.theme.keepInMenuBar = settings.theme.keepInMenuBar
        // the compare mode/gain reach the pipeline through pushCompare, not
        // through the capture config — a mode click must not rebuild capture
        pipelineRelevant.review.compareMode = settings.review.compareMode
        pipelineRelevant.review.compareDifferenceGain = settings.review.compareDifferenceGain
        guard pipelineRelevant != settings else { return }
        pushConfig()
    }

    /// Hardware and destination: each of these restarts something.
    private func applyDeviceChange(from oldValue: CaptureSettings) {
        if oldValue.capture.monitorDeviceID != settings.capture.monitorDeviceID {
            rebuildPlayout()
        }
        if oldValue.capture.destinationPath != settings.capture.destinationPath {
            resetLibraryForNewDestination()
            startFolderWatcher()
        }
        if oldValue.capture.forcedInputMode != settings.capture.forcedInputMode
            || oldValue.capture.forcedInputRGB != settings.capture.forcedInputRGB {
            restartCapture()
        }
        // The bit-depth picker used to restart capture from here. It is gone —
        // depth follows the signal — but the CODEC still has something to say
        // about a 12-bit one: 4:2:2 subsamples it on the way into the file, and
        // that used to be a consequence of the operator's own 12-bit click.
        // Nothing restarts; the notice is simply re-asked, because the signal
        // that would otherwise have carried it has not changed.
        if oldValue.capture.codec != settings.capture.codec {
            reportBitDepth(signalFormat)
        }
    }

    /// cam/postfix/template/padding all feed the filename — recompute the
    /// "this name is already taken" warning.
    private func applyNamingChange(from oldValue: CaptureSettings) {
        guard oldValue.naming.cameraLabel != settings.naming.cameraLabel
            || oldValue.naming.postfix != settings.naming.postfix
            || oldValue.naming.namingTemplate != settings.naming.namingTemplate
            || oldValue.naming.clipPadWidth != settings.naming.clipPadWidth else { return }
        refreshNameCollision()
    }
}
