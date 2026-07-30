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

    /// Speaker click in the audio panel: mute/unmute the volume with restore.
    /// It never disables the output path — the slider always stays live.
    func toggleMonitorMute() {
        if !monitorOn {
            monitorOn = true
            if monitorVolume == 0 { setVolume(monitorVolumeBeforeMute, persist: false) }
            return
        }
        if monitorVolume > 0 {
            monitorVolumeBeforeMute = monitorVolume
            // mute is transient: persisting 0 made every launch start silent
            setVolume(0, persist: false)
        } else {
            setVolume(monitorVolumeBeforeMute > 0 ? monitorVolumeBeforeMute : 1,
                      persist: false)
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
    /// `CaptureSettings.monitorDimmed` for why never the halved level.
    private func persistDimState() {
        dimPersistTask?.cancel()
        let dimmed = live.dimmed
        dimPersistTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            self.settings.monitorDimmed = dimmed ? true : nil
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
        // slider, the number field) from the transient holds — mute and DIM.
        // Once the level has been set by hand, DIM's restore point is stale and
        // its highlight would be claiming a state the level no longer has.
        if persist, live.dimmed {
            live.dimmed = false
            persistDimState()
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
            self.settings.monitorVolume = level
        }
    }

    // MARK: - audio channels (record mask)

    /// Whether the channel is included in the recording.
    func isChannelEnabled(_ index: Int) -> Bool {
        guard let mask = settings.audioChannelMask else { return true }
        return mask & (1 << index) != 0
    }

    func toggleAudioChannel(_ index: Int) {
        var mask = settings.audioChannelMask ?? 0xFFFF
        mask ^= (1 << index)
        // all enabled — store nil (= "all", including if more channels appear later)
        settings.audioChannelMask = (mask & 0xFFFF) == 0xFFFF ? nil : mask
    }

    /// The mix bank: channels 1-2, where the sound department's stereo mix
    /// arrives on every rig there is.
    static let mixChannelMask = 0b11

    /// The record mask is currently the mix and nothing else.
    var isRecordingMixOnly: Bool {
        settings.audioChannelMask == Self.mixChannelMask
    }

    /// One key for the whole channel decision: record the mix on 1-2, or record
    /// everything that was selected before.
    ///
    /// This is deliberately NOT "flip channels 1-8" or "flip 9-16". A bank of
    /// eight has no meaning on set — the mix is on 1-2 and the ISO tracks start
    /// at 3, and 9-16 are usually not even in the embed, so a key for them looks
    /// broken. Worse, flipping a range by XOR turns silent channels ON whenever
    /// the operator had part of the range selected (1-4 selected, flip 3-16, and
    /// twelve empty tracks join the take). Going to a fixed 1-2 and coming back
    /// to the remembered selection cannot do that: the two states are always the
    /// mix and exactly what the operator chose.
    ///
    /// Refused while recording, for the reason the panel's channel columns are:
    /// the mask is latched per take (`CapturePipeline+Take`) and the writer's
    /// channel count is fixed, so a mid-take change would desync the two while
    /// looking like it had been applied.
    func toggleAudioChannelBank() {
        guard !isRecording else { return }
        if isRecordingMixOnly {
            // 0xFFFF is what "all channels" is stored as (see toggleAudioChannel)
            settings.audioChannelMask = audioMaskBeforeMixOnly == 0xFFFF
                ? nil : audioMaskBeforeMixOnly
            return
        }
        audioMaskBeforeMixOnly = settings.audioChannelMask ?? 0xFFFF
        settings.audioChannelMask = Self.mixChannelMask
    }

    /// Playback audio output (also used by the live monitor).
    var playbackOutputUID: String? {
        get { settings.playbackAudioDeviceUID }
        set {
            settings.playbackAudioDeviceUID = newValue
            player.audioOutputDeviceUniqueID = newValue
            audioMonitor.outputDeviceUID = newValue
        }
    }
}
