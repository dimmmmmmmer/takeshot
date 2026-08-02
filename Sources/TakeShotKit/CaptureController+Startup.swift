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
        L10n.apply(stored.appLanguage.flatMap(AppLanguage.init(rawValue:)) ?? .english)
        player.audioOutputDeviceUniqueID = stored.playbackAudioDeviceUID
        audioMonitor.outputDeviceUID = stored.playbackAudioDeviceUID
        // 0 in old saves came from the mute button, not a chosen level
        let storedVolume = (stored.monitorVolume ?? 1) > 0
            ? (stored.monitorVolume ?? 1) : 1
        audioMonitor.volume = Float(storedVolume)
        live.volume = storedVolume
        live.lutIntensity = stored.lutIntensity ?? 1
        monitorOn = stored.monitorEnabled ?? true
        restoreCompare(from: stored)
        restoreAssists(from: stored)
        player.volume = Float(storedVolume)
        // A DIM left engaged comes back engaged: the stored level is the one the
        // operator set, so the hold is re-applied on top of it and the restore
        // point is that level exactly. Quiet, but never unexplained — the DIM
        // badge in the footer is lit (this is why the state is persisted and the
        // halved level is not; see CaptureSettings.monitorDimmed).
        if stored.monitorDimmed == true {
            live.dimmed = true
            live.volumeBeforeDim = storedVolume
            let held = storedVolume * Self.dimAttenuation
            live.volume = held
            audioMonitor.volume = Float(held)
            player.volume = Float(held)
        }
        // A mute left engaged comes back engaged, on top of whatever level is
        // in force by now (the dimmed one if DIM is also being restored), and
        // that level is exactly what the un-mute puts back. Quiet, but never
        // unexplained — the footer speaker shows the slash. Same reasoning as
        // DIM above; see CaptureSettings.monitorMuted.
        if stored.monitorMuted == true {
            live.muted = true
            monitorVolumeBeforeMute = live.volume
            live.volume = 0
            audioMonitor.volume = 0
            player.volume = 0
        }
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
        startFolderSync()
        refreshNameCollision()
        applyLetterboxColor()
        reloadLUTList()
        // the persisted LUT + "apply to preview" must take effect immediately —
        // without this the checkbox showed enabled while nothing was applied
        rebuildLUT()
        rebuildPlayout()
        startDiskWatch()
        // The offload model reports back through the controller (status line,
        // toast, sticky alarm), so it is wired for the controller's lifetime and
        // not at the moment the sheet happens to open.
        offload.attach(to: self)
        verify.attach(to: self)
        // …and what was offloaded before this launch, for the same reason: the
        // sheet has to be able to show it the instant it opens, and a run can
        // append to it while the sheet has never been on screen.
        offloadHistory.load()
        // The web remote comes back up if the operator left it on — a director
        // holding the phone from yesterday should not have to be told to go and
        // find the laptop after a relaunch. Off by default; nothing binds a port
        // until it is switched on once.
        startRemoteIfEnabled()
    }

    /// The operator aids that outlive a session: the desqueeze factor, the
    /// peaking tint and the chroma key's dial-in. Each is an assignment to
    /// `assist`, whose observer pushes it to every surface — grouped into one
    /// call so that adding the next one does not push `completeStartup` past
    /// the length at which nobody reads a function top to bottom.
    private func restoreAssists(from stored: CaptureSettings) {
        assist.desqueeze = stored.desqueezeFactor ?? 1
        assist.peakingColor = stored.peakingColor
            .flatMap(ViewAssist.PeakingColor.init(rawValue:)) ?? .red
        // the key comes back dialled in and switched OFF (see restoreChroma)
        restoreChroma(from: stored)
    }

    /// The compare mode and its gain come back like every other working
    /// preference. Gain first: each didSet pushes the whole compare state, and
    /// the mode's push should already carry the restored gain.
    private func restoreCompare(from stored: CaptureSettings) {
        differenceGain = stored.compareDifferenceGain
            .flatMap(DifferenceGain.init(rawValue:)) ?? .x1
        compareMode = stored.compareMode
            .flatMap(CompareMode.init(rawValue:)) ?? .off
    }
}
