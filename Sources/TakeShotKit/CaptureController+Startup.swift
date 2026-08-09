import AVFoundation
import AppKit
import CaptureCore
import Foundation
import SwiftUI

/// Everything `init` does after the stored properties exist: the shipping
/// backend set, restoring persisted state, and wiring the long-lived
/// callbacks. Called exactly once, from `init` — a separate file because the
/// class file is the stored state's inventory and each merge was outgrowing
/// the file-length limit.
extension CaptureController {
    /// What the app itself runs on: the DeckLink bridge plus the demo source.
    /// The demo source is always last; when a real board appears the app
    /// switches to it automatically (see refreshDevices).
    static func shippingBackends() -> [(String, CaptureBackend)] {
        [("decklink", DeckLinkBackendAdapter()),
         ("mock", MockCaptureBackend())]
    }

    /// Everything `init` does after the stored properties exist: restore the
    /// persisted state and wire the long-lived callbacks. Called exactly once,
    /// from `init` — it lives here only because the class file is the stored
    /// state's inventory and was outgrowing the file-length limit.
    func completeStartup(stored: CaptureSettings) {
        L10n.apply(stored.theme.appLanguage.flatMap(AppLanguage.init(rawValue:)) ?? .english)
        player.audioOutputDeviceUniqueID = stored.audio.playbackAudioDeviceUID
        audioMonitor.outputDeviceUID = stored.audio.playbackAudioDeviceUID
        // 0 in old saves came from the mute button, not a chosen level
        let storedVolume = (stored.audio.monitorVolume ?? 1) > 0
            ? (stored.audio.monitorVolume ?? 1) : 1
        audioMonitor.volume = Float(storedVolume)
        live.volume = storedVolume
        live.lutIntensity = stored.lut.intensity ?? 1
        monitorOn = stored.audio.monitorEnabled ?? true
        restoreCompare(from: stored)
        restoreAssists(from: stored)
        player.volume = Float(storedVolume)
        restoreMonitorHolds(from: stored, storedVolume: storedVolume)
        transport.attach(player) // one attachment for the app's lifetime
        // in/out survives a relaunch: the transport says when a range moved, the
        // sidecar in the record folder is where it goes (see exportClipRanges)
        transport.onRangesChanged = { [weak self] in self?.exportClipRanges() }
        bindPipeline()
        playbackTap.setLiveBufferProvider { [pipeline] in
            pipeline.currentPreviewBuffer()
        }
        // …and the pre-LUT stage of the same frame, for the difference
        // compare: it measures code values, so its back half must not carry
        // the preview LUT the display buffer does.
        playbackTap.setLivePreLUTBufferProvider { [pipeline] in
            pipeline.currentPreLUTPreviewBuffer()
        }
        refreshDevices() // selecting the first device starts capture via didSet
        // the stored USB audio source comes back like the output device does;
        // a device missing at launch falls back to embedded with the warning
        if stored.audio.audioInputDeviceUID != nil { rebuildExternalAudioSource() }
        startFolderSync()
        refreshNameCollision()
        applyLetterboxColor()
        reloadLUTList()
        // the persisted LUT + "apply to preview" must take effect immediately —
        // without this the checkbox showed enabled while nothing was applied
        rebuildLUT()
        rebuildPlayout()
        startDiskWatch()
        attachBackgroundJobModels()
        attachAppLevelPresences()
    }

    /// The three presences that outlive the main window.
    private func attachAppLevelPresences() {
        // Quitting finalizes a take in progress, and the delegate reaches it
        // through this reference (`applicationWillTerminate` →
        // `flushOnTerminate`). Claimed here rather than only from ContentView's
        // onAppear, which is exactly what has NOT run when the app is quit from
        // the menu bar with no window open. nil in a test — there is no
        // delegate in one.
        AppDelegate.shared?.controller = self
        // The web remote comes back up if the operator left it on — a director
        // holding the phone from yesterday should not have to be told to go and
        // find the laptop after a relaunch. Off by default; nothing binds a port
        // until it is switched on once.
        startRemoteIfEnabled()
        // …the NDI source, on exactly the same terms: nothing is announced on
        // the set network until the switch has been thrown once, and a shoot
        // that left it on gets its source back after a relaunch (see +NDI).
        startNDIIfEnabled()
        // …and the menu-bar item, on the same terms: off by default, and back
        // where it was left for anyone who switched it on (see +MenuBar).
        updateMenuBarPresence()
    }

    /// The long-running-job models (offload, verify, dailies) and the card
    /// watch, wired for the controller's lifetime rather than when a sheet
    /// happens to open: each reports back through the controller (status line,
    /// toast, sticky alarm), and one started any other way would run perfectly
    /// silently. The dailies queue has one reason more — the REC state has to
    /// reach it (recording pauses the queue) with no sheet on screen at all.
    private func attachBackgroundJobModels() {
        offload.attach(to: self)
        verify.attach(to: self)
        dailies.attach(to: self)
        // …and what was offloaded before this launch, for the same reason: the
        // sheet has to be able to show it the instant it opens, and a run can
        // append to it while the sheet has never been on screen.
        offloadHistory.load()
        // …and the watch for cards mounted from here on. No initial enumeration
        // on purpose: only a volume that appears while the app is running is
        // ever asked about (see `WorkspaceVolumeWatch`).
        startCardWatch()
    }

    /// The two persisted monitoring HOLDS, re-applied over the stored level.
    ///
    /// A DIM left engaged comes back engaged: the stored level is the one the
    /// operator set, so the hold is re-applied on top of it and the restore
    /// point is that level exactly. Quiet, but never unexplained — the DIM
    /// badge in the footer is lit (this is why the state is persisted and the
    /// halved level is not; see AudioSettings.monitorDimmed).
    ///
    /// A mute left engaged comes back engaged, on top of whatever level is in
    /// force by then (the dimmed one if DIM is also being restored), and that
    /// level is exactly what the un-mute puts back — the footer speaker shows
    /// the slash. Same reasoning; see AudioSettings.monitorMuted.
    private func restoreMonitorHolds(from stored: CaptureSettings,
                                     storedVolume: Double) {
        if stored.audio.monitorDimmed == true {
            live.dimmed = true
            live.volumeBeforeDim = storedVolume
            let held = storedVolume * Self.dimAttenuation
            live.volume = held
            audioMonitor.volume = Float(held)
            player.volume = Float(held)
        }
        if stored.audio.monitorMuted == true {
            live.muted = true
            monitorVolumeBeforeMute = live.volume
            live.volume = 0
            audioMonitor.volume = 0
            player.volume = 0
        }
    }

    /// The operator aids that outlive a session: the desqueeze factor, the
    /// peaking tint and the chroma key's dial-in. Each is an assignment to
    /// `assist`, whose observer pushes it to every surface — grouped into one
    /// call so that adding the next one does not push `completeStartup` past
    /// the length at which nobody reads a function top to bottom.
    private func restoreAssists(from stored: CaptureSettings) {
        assist.desqueeze = stored.assist.desqueezeFactor ?? 1
        assist.peakingColor = stored.assist.peakingColor
            .flatMap(ViewAssist.PeakingColor.init(rawValue:)) ?? .red
        // the framelines and the exposure legend are settings rather than
        // assist state, but they are DRAWN with the aids now, so the drawn
        // values have to be seeded too
        assist.guides = AssistGuides(settings: stored.assist)
        assist.legend = AssistLegend(settings: stored.assist)
        // clamped, not trusted: the blob may have been written by a build with
        // a different ceiling, or hand-edited
        assist.peakingIntensity = min(
            ViewAssist.maxPeakingIntensity,
            max(0, stored.assist.peakingIntensity ?? ViewAssist().peakingIntensity))
        // the key comes back dialled in and switched OFF (see restoreChroma)
        restoreChroma(from: stored.chromaKey)
        // …and so does the taught REC indicator, for a stronger reason: its
        // references are a photograph of one camera's overlay (see
        // restoreVisualRec)
        restoreVisualRec(from: stored.visualRec)
    }

    /// The compare mode and its gain come back like every other working
    /// preference. Gain first: each didSet pushes the whole compare state, and
    /// the mode's push should already carry the restored gain.
    private func restoreCompare(from stored: CaptureSettings) {
        differenceGain = stored.review.compareDifferenceGain
            .flatMap(DifferenceGain.init(rawValue:)) ?? .x1
        compareMode = stored.review.compareMode
            .flatMap(CompareMode.init(rawValue:)) ?? .off
    }
}
