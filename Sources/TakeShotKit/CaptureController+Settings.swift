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
        // The REC-indicator trigger follows the detection MODE: choosing another
        // mode must take it down, and choosing this one arms it if the box has
        // been taught. Stated here rather than in the picker, because a settings
        // blob and the mode menu on the timecode badge are both callers.
        // AUTO means "everything this signal offers", so the indicator counts
        // there too (owner: "авто режим река должен учитывать и рек индикатор")
        // — it is the only evidence an HDMI camera with no running timecode
        // gives at all. Still refused while untaught: the setter below sees to
        // that, so auto on an untaught box is simply auto without it.
        let wantsVisual = RecDetectionMode.visualModes
            .contains(settings.capture.detectionMode)
        if visualRecTeaching.isOn != (wantsVisual && visualRecTeaching.isTaught) {
            visualRecOn = wantsVisual
        }

        settings.save(to: defaults)
        // A settings write fans out only to the subsystems the change actually
        // touches: a volume slider tick lands here too, and rebuilding the
        // world on every one of them is what made the sliders lag.
        applyLanguageChange(from: oldValue)
        applyPipelineChange(from: oldValue)
        applyDeviceChange(from: oldValue)
        applyAudioInputChange(from: oldValue)
        applyNamingChange(from: oldValue)
        applyR3DChange(from: oldValue)
        applyRemoteChange(from: oldValue)
        applySRTChange(from: oldValue)
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
        // Three WHOLE groups the pipeline has never heard of. The remote is a
        // socket, and SRT and NDI are display mirrors wired outside the capture
        // config — flicking any of those switches, or typing in the SRT address
        // or the NDI name field, must not rebuild capture mid-take. Masking the
        // group rather than its fields one by one is also what keeps this honest
        // when a field is added to any of them: it stays out of the capture
        // config by default, which is the safe direction.
        pipelineRelevant.remote = settings.remote
        pipelineRelevant.srt = settings.srt
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

    /// The two R3D decode options reach the clip that is ALREADY open.
    ///
    /// Both are read once, in `openRawClip`, because the decoder is built around
    /// them — the scale has to be fixed before the first frame is asked for and
    /// the camera LUT is a property of the decode. So neither could ever reach
    /// the clip on screen, and the clip on screen is the whole reason the scale
    /// picker exists: it is chosen while an 8K clip is stuttering, and it did
    /// nothing until the next clip was opened.
    ///
    /// Reopening is the only way to apply it, so that is what this does —
    /// putting the playhead and the play state back, because a picker click is
    /// not a request to start the clip again from the top.
    private func applyR3DChange(from oldValue: CaptureSettings) {
        guard oldValue.r3d.decodeScale != settings.r3d.decodeScale
            || oldValue.r3d.applyCameraLUT != settings.r3d.applyCameraLUT
        else { return }
        reopenR3DClip()
    }

    /// Whether the two R3D options have anything in the player to reach.
    ///
    /// The clip's own format and not "is a RAW engine loaded": BRAW and
    /// CinemaDNG go through the same engine and neither decoder has ever read
    /// these options, so a scale click must not disturb them. Named rather than
    /// inlined because it is what makes the wiring assertable in a build with no
    /// RED SDK — which is what CI and every published build are.
    var playbackIsR3D: Bool {
        playbackURL?.pathExtension.lowercased() == "r3d"
    }

    /// Reopen the R3D clip in the player with the current decode options, at the
    /// frame and in the state it was in. Nothing to do for any other format: the
    /// options belong to R3D's decoder and BRAW/CinemaDNG never read them.
    func reopenR3DClip() {
        guard playbackIsR3D, let url = playbackURL else { return }
        let frame = rawPlayer?.currentFrame ?? 0
        let wasPlaying = rawPlayer?.isPlaying ?? false
        let wasLooping = rawPlayer?.isLooping ?? false
        // `play(url:)` is the real open path — it files the outgoing engine's
        // in/out points and hands them back to the new one — so the range the
        // operator marked survives the reopen rather than being reconstructed
        // here.
        play(url: url)
        // A clip that would not open again has already said why
        // (`rawPlayerError`); there is nothing to put the playhead back into.
        guard let fresh = rawPlayer else { return }
        fresh.isLooping = wasLooping
        // A fresh engine is playing (see `openRawClip`); the seek carries the
        // play state through, so pausing FIRST is what leaves a paused clip
        // paused on the frame it was parked on.
        if !wasPlaying { fresh.pause() }
        fresh.seek(to: frame)
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
