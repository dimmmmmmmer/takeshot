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
        live.volume = newValue
        audioMonitor.volume = Float(newValue)
        player.volume = Float(newValue)
        // dragging the volume up implies "I want to hear it" (live monitor only)
        if newValue > 0, !monitorOn, isCapturing, viewerMode == .record {
            monitorOn = true
        }
        volumePersistTask?.cancel()
        guard persist else { return }
        volumePersistTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            self.settings.monitorVolume = self.live.volume
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
