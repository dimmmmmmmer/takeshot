import CaptureCore
import Foundation

/// Which audio channels go into the recording, and which output the operator
/// hears it on.
///
/// Split out of `+Audio`: the monitoring level is one job and the record mask
/// is another — the mask is latched per take by the writer, so it is the half
/// with a recording-integrity rule on it.
extension CaptureController {

    /// Whether the channel is included in the recording.
    func isChannelEnabled(_ index: Int) -> Bool {
        guard let mask = settings.audio.audioChannelMask else { return true }
        return mask & (1 << index) != 0
    }

    func toggleAudioChannel(_ index: Int) {
        var mask = settings.audio.audioChannelMask ?? 0xFFFF
        mask ^= (1 << index)
        // all enabled — store nil (= "all", including if more channels appear later)
        settings.audio.audioChannelMask = (mask & 0xFFFF) == 0xFFFF ? nil : mask
    }

    /// The mix bank: channels 1-2, where the sound department's stereo mix
    /// arrives on every rig there is.
    static let mixChannelMask = 0b11

    /// The record mask is currently the mix and nothing else.
    var isRecordingMixOnly: Bool {
        settings.audio.audioChannelMask == Self.mixChannelMask
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
            settings.audio.audioChannelMask = audioMaskBeforeMixOnly == 0xFFFF
                ? nil : audioMaskBeforeMixOnly
            return
        }
        audioMaskBeforeMixOnly = settings.audio.audioChannelMask ?? 0xFFFF
        settings.audio.audioChannelMask = Self.mixChannelMask
    }

    /// Playback audio output (also used by the live monitor).
    var playbackOutputUID: String? {
        get { settings.audio.playbackAudioDeviceUID }
        set {
            settings.audio.playbackAudioDeviceUID = newValue
            player.audioOutputDeviceUniqueID = newValue
            audioMonitor.outputDeviceUID = newValue
        }
    }
}
