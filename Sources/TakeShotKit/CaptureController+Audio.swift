import AVFoundation
import AppKit
import CaptureCore
import CoreMedia
import Foundation
import SwiftUI

/// Monitoring the sound: the live monitor, the one shared volume, the record
/// channel mask and the output device.
///
/// Split out of CaptureController: the type had grown past 2600 lines, the
/// size at which nobody reads it top to bottom any more.
extension CaptureController {
    /// Per-channel audio peak levels, dBFS (for the meters; see `live`).
    var audioLevels: [Float] { live.audioLevels }

    /// The one full mute: the speaker icon's click, the audio panel's speaker
    /// button and the ⌃A hotkey all land here, so the icon and the key can
    /// never disagree about whether the room is silent.
    ///
    /// Mute is a HOLD, not a level: the level it took away comes back exactly
    /// on un-mute, and the state itself is what persists (like DIM — see
    /// `AudioSettings.monitorMuted` for why never the zero). It never
    /// disables the output path — the slider always stays live.
    func toggleMonitorMute() {
        if live.muted {
            live.muted = false
            // un-muting means "I want to hear it": a live monitor switched off
            // underneath the mute comes back on with it, as the speaker button
            // always did
            if !monitorOn { monitorOn = true }
            setVolume(monitorVolumeBeforeMute > 0 ? monitorVolumeBeforeMute : 1,
                      persist: false)
        } else {
            // the level in force right now — the dimmed one if DIM is holding —
            // is what the un-mute puts back; DIM itself stays engaged across
            // the mute (see dimAndMuteCompose in the audio tests)
            monitorVolumeBeforeMute = live.volume
            live.muted = true
            setVolume(0, persist: false)
        }
        persistMuteState()
    }

    /// The mute state is persisted on the same debounce as the volume slider
    /// and the DIM hold, for the same reason: a settings write fans out through
    /// `applySettingsChange` and re-renders the window, and this control sits
    /// among the meters and on a hotkey. What is stored is the state alone —
    /// see `AudioSettings.monitorMuted` for why never the zero.
    private func persistMuteState() {
        mutePersistTask?.cancel()
        let muted = live.muted
        mutePersistTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            self.settings.audio.monitorMuted = muted ? true : nil
        }
    }

    // MARK: - dim

    /// How far DIM pulls the monitoring level down. Half, like Resolve's dim
    /// button: enough to talk over the take, not so much that a sync problem
    /// stops being audible.
    static let dimAttenuation = 0.5

    /// DIM: one click holds monitoring at half level, the next puts back exactly
    /// what was there. A method (not a binding) because a hotkey binds to it in
    /// a later wave, and because the restore level has to be remembered
    /// somewhere both the button and the hotkey agree on.
    ///
    /// Dimming silence is refused rather than allowed as a no-op: the state is
    /// shown as a highlight, and a highlight that claims a dim which is not
    /// holding anything down would survive the next un-mute and lie about the
    /// level.
    func toggleMonitorDim() {
        if live.dimmed {
            live.dimmed = false
            setVolume(live.volumeBeforeDim, persist: false)
            persistDimState()
            return
        }
        guard live.volume > 0 else { return }
        live.volumeBeforeDim = live.volume
        live.dimmed = true
        setVolume(live.volume * Self.dimAttenuation, persist: false)
        persistDimState()
    }

    /// The dim state is persisted on the same debounce as the volume slider, and
    /// for the same reason: a settings write fans out through `applySettingsChange`
    /// and re-renders the window, and this button sits among the meters, which a
    /// hotkey can hammer. What is stored is the state alone — see
    /// `AudioSettings.monitorDimmed` for why never the halved level.
    private func persistDimState() {
        dimPersistTask?.cancel()
        let dimmed = live.dimmed
        dimPersistTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            self.settings.audio.monitorDimmed = dimmed ? true : nil
        }
    }

    /// Whether DIM can do anything right now: something has to be monitoring,
    /// and there has to be a level to take away.
    var canDimMonitoring: Bool {
        guard isCapturing || viewerMode == .playback else { return false }
        return live.dimmed || live.volume > 0
    }

    /// The live feed is only monitored while the viewer is showing it. Without
    /// this the capture audio kept playing over a clip in playback — two sound
    /// sources at once, and the operator hears the room instead of the take.
    /// `monitorOn` stays the operator's preference and is not overwritten.
    func updateAudioMonitorRouting() {
        let live = monitorOn && viewerMode == .record
        pipeline.setAudioMonitorEnabled(live)
        if !live { audioMonitor.stop() }
    }

    /// One volume for the live monitor and the player: switching rec↔playback
    /// must not change loudness. Applied immediately, persisted debounced —
    /// writing settings on every drag tick re-rendered the whole window
    /// (slider lag).
    var monitorVolume: Double {
        get { live.volume }
        set { setVolume(newValue) }
    }

    var playbackVolume: Double {
        get { live.volume }
        set { setVolume(newValue) }
    }

    private func setVolume(_ newValue: Double, persist: Bool = true) {
        // `persist` is also what separates the operator setting the level (the
        // slider, the number field) from the holds — mute and DIM. Once the
        // level has been set by hand, either hold's restore point is stale and
        // its highlight (or slashed speaker) would be claiming a state the
        // level no longer has.
        if persist, live.dimmed {
            live.dimmed = false
            persistDimState()
        }
        if persist, live.muted {
            live.muted = false
            persistMuteState()
        }
        live.volume = newValue
        audioMonitor.volume = Float(newValue)
        player.volume = Float(newValue)
        // dragging the volume up implies "I want to hear it" (live monitor only)
        if newValue > 0, !monitorOn, isCapturing, viewerMode == .record {
            monitorOn = true
        }
        // A transient hold leaves a pending write alone. It used to cancel it,
        // and the level of a drag that was muted or dimmed inside the debounce
        // window was then never persisted at all.
        guard persist else { return }
        volumePersistTask?.cancel()
        // The level to store is the one being set, not `live.volume` 400 ms
        // later: a mute in between would otherwise store its zero, which is the
        // "every launch starts silent" bug (see toggleMonitorMute).
        let level = newValue
        volumePersistTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            self.settings.audio.monitorVolume = level
        }
    }
}
