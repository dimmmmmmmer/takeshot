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
        applyCardWatchChange(from: oldValue)
        applyMenuBarChange(from: oldValue)
    }

    /// Bundle lookups hit the disk — only on an actual language change.
    private func applyLanguageChange(from oldValue: CaptureSettings) {
        guard oldValue.appLanguage != settings.appLanguage else { return }
        L10n.apply(appLanguage)
    }

    /// The pipeline only needs a push when something it reads has changed; the
    /// monitoring level, the DIM and mute holds and the web remote are the
    /// fields it does not read — the holds are applied straight to the monitor
    /// and the remote is a socket, and rebuilding the capture config per dim or
    /// mute click (or per remote toggle) would make the sliders lag for nothing.
    private func applyPipelineChange(from oldValue: CaptureSettings) {
        var pipelineRelevant = oldValue
        pipelineRelevant.monitorVolume = settings.monitorVolume
        pipelineRelevant.monitorDimmed = settings.monitorDimmed
        pipelineRelevant.monitorMuted = settings.monitorMuted
        pipelineRelevant.remoteEnabled = settings.remoteEnabled
        pipelineRelevant.remotePort = settings.remotePort
        pipelineRelevant.remotePIN = settings.remotePIN
        // the status item is a window-level affordance; the writer has never
        // heard of it, and toggling it must not rebuild the capture config
        pipelineRelevant.keepInMenuBar = settings.keepInMenuBar
        // the compare mode/gain reach the pipeline through pushCompare, not
        // through the capture config — a mode click must not rebuild capture
        pipelineRelevant.compareMode = settings.compareMode
        pipelineRelevant.compareDifferenceGain = settings.compareDifferenceGain
        guard pipelineRelevant != settings else { return }
        pushConfig()
    }

    /// Hardware and destination: each of these restarts something.
    private func applyDeviceChange(from oldValue: CaptureSettings) {
        if oldValue.monitorDeviceID != settings.monitorDeviceID {
            rebuildPlayout()
        }
        if oldValue.destinationPath != settings.destinationPath {
            resetLibraryForNewDestination()
            startFolderWatcher()
        }
        if oldValue.forcedInputMode != settings.forcedInputMode
            || oldValue.forcedInputRGB != settings.forcedInputRGB
            || oldValue.tenBitCapture != settings.tenBitCapture {
            restartCapture()
        }
    }

    /// cam/postfix/template/padding all feed the filename — recompute the
    /// "this name is already taken" warning.
    private func applyNamingChange(from oldValue: CaptureSettings) {
        guard oldValue.cameraLabel != settings.cameraLabel
            || oldValue.postfix != settings.postfix
            || oldValue.namingTemplate != settings.namingTemplate
            || oldValue.clipPadWidth != settings.clipPadWidth else { return }
        refreshNameCollision()
    }
}
