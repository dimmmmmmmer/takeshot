import CaptureCore
import Foundation

/// Which audio channels go into the recording, and which output the operator
/// hears it on.
///
/// Split out of `+Audio`: the monitoring level is one job and the record mask
/// is another — the mask is latched per take by the writer, so it is the half
/// with a recording-integrity rule on it.
///
/// **Two answers, and auto only ever fills the nil.** The mask a take records
/// is the operator's when they have chosen channels, and the standby
/// measurement's (`AudioChannelDetector`) when they have not. Nothing here
/// overrides a choice, and nothing here is a choice the operator has to make
/// before the measurement is allowed to work — which is what makes it the
/// default rather than a mode.
extension CaptureController {

    /// Whether the measurement is allowed to answer. nil is on, which is what
    /// makes it the default for an install that predates it.
    var audioChannelsAuto: Bool { settings.audio.audioChannelAuto ?? true }

    /// The mask a take opened now would record — the same expression the
    /// pipeline latches, restated here because the panel has to draw it and
    /// cannot reach onto the capture queue to ask.
    ///
    /// The two cannot drift on the mask itself: both read the same settings and
    /// the same detected answer, and the detected answer arrives here on the
    /// pipeline's own callback (`onAudioChannelsDetected`).
    var effectiveAudioChannelMask: Int? {
        let chosen = settings.audio.audioChannelMask
        guard audioChannelsAuto else { return chosen }
        return chosen ?? detectedAudioChannelMask
    }

    /// The measurement is what is deciding right now: auto is on and the
    /// operator has chosen nothing.
    var isAudioChannelsAutomatic: Bool {
        audioChannelsAuto && settings.audio.audioChannelMask == nil
    }

    /// Whether the channel is included in the recording.
    func isChannelEnabled(_ index: Int) -> Bool {
        guard let mask = effectiveAudioChannelMask else { return true }
        return mask & (1 << index) != 0
    }

    /// The channel decision is the operator's to change while nothing is
    /// rolling, and nobody's while a take is.
    ///
    /// The mask is latched per take (`CapturePipeline+Take`) and the writer's
    /// channel count is fixed with it, so a mid-take change would desync the
    /// two while looking like it had been applied. Named here rather than
    /// spelled at the panel, next to the rules it governs — the channel
    /// columns, the mix key and the auto switch all ask this one.
    var canChangeAudioChannels: Bool { !isRecording }

    /// Turning a channel off (or on) is the operator taking the decision.
    ///
    /// It starts from the mask IN FORCE rather than from "all on", so a first
    /// click on a channel the measurement had already excluded does not switch
    /// fourteen silent tracks back on behind it — which is what a fixed 0xFFFF
    /// start would have done the moment auto began answering.
    func toggleAudioChannel(_ index: Int) {
        guard canChangeAudioChannels else { return }
        var mask = effectiveAudioChannelMask ?? 0xFFFF
        mask ^= (1 << index)
        // From here the operator owns it: the measurement must not quietly
        // widen or narrow a selection somebody made by hand between takes.
        settings.audio.audioChannelAuto = false
        // all enabled — store nil (= "all", including if more channels appear later)
        settings.audio.audioChannelMask = (mask & 0xFFFF) == 0xFFFF ? nil : mask
    }

    /// Hand the decision back to the measurement, or take it away.
    ///
    /// On: the stored mask goes too. It has to — auto fills the nil, so a mask
    /// left behind would keep answering and the switch would look broken.
    /// Off: what auto had chosen is written down as the operator's own mask, so
    /// switching it off changes who decides and not what is recorded. Turning
    /// it off used to be the only state there was, and it is still exactly
    /// today's behaviour: nil mask, every declared channel.
    func setAudioChannelsAuto(_ on: Bool) {
        guard canChangeAudioChannels else { return }
        if on {
            settings.audio.audioChannelAuto = nil // nil is on; see the setting
            settings.audio.audioChannelMask = nil
            return
        }
        let held = effectiveAudioChannelMask
        settings.audio.audioChannelAuto = false
        settings.audio.audioChannelMask =
            (held.map { $0 & 0xFFFF } == 0xFFFF) ? nil : held
    }

    /// The mix bank: channels 1-2, where the sound department's stereo mix
    /// arrives on every rig there is.
    static let mixChannelMask = 0b11

    /// The record mask is currently the mix and nothing else.
    ///
    /// What is IN FORCE, not what is stored: with auto answering "1-2 carry
    /// signal" on a camera that embeds stereo, the mix key would otherwise
    /// offer to switch to the state it is already in.
    var isRecordingMixOnly: Bool {
        effectiveAudioChannelMask == Self.mixChannelMask
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
    /// What it comes BACK to now includes "the measurement was deciding", which
    /// is a state the remembered mask alone cannot express — so the auto flag is
    /// remembered with it. Without that, one press of the mix key would have
    /// been a one-way door out of auto for the rest of the session.
    ///
    /// Refused while recording, for the reason the panel's channel columns are:
    /// the mask is latched per take (`CapturePipeline+Take`) and the writer's
    /// channel count is fixed, so a mid-take change would desync the two while
    /// looking like it had been applied.
    func toggleAudioChannelBank() {
        guard canChangeAudioChannels else { return }
        if isRecordingMixOnly {
            if audioAutoBeforeMixOnly {
                setAudioChannelsAuto(true)
                return
            }
            settings.audio.audioChannelAuto = false
            // 0xFFFF is what "all channels" is stored as (see toggleAudioChannel)
            settings.audio.audioChannelMask = audioMaskBeforeMixOnly == 0xFFFF
                ? nil : audioMaskBeforeMixOnly
            return
        }
        audioAutoBeforeMixOnly = isAudioChannelsAutomatic
        audioMaskBeforeMixOnly = effectiveAudioChannelMask ?? 0xFFFF
        settings.audio.audioChannelAuto = false
        settings.audio.audioChannelMask = Self.mixChannelMask
    }

    /// What the channels panel says about who chose the mask, in one line.
    ///
    /// Four states, and they are four because "the measurement has not answered
    /// yet" is genuinely different from "the measurement answered": the first
    /// one records every channel, exactly as this app always did, and an
    /// operator who is told "auto" and shown sixteen lit meters has to be able
    /// to read that as the measurement still listening rather than as it being
    /// broken. This is the first take after launch, and it is the state the
    /// first second of every session is in.
    var audioChannelDecisionText: String {
        guard isAudioChannelsAutomatic else {
            let mask = settings.audio.audioChannelMask
            let list = mask.map { AudioChannelList.describe($0, upTo: audioChannelCount) }
            return String(format: L("audio_channels_manual"),
                          list ?? L("audio_channels_all"))
        }
        guard let detected = detectedAudioChannelMask else {
            return L("audio_channels_auto_listening")
        }
        return String(format: L("audio_channels_auto_detected"),
                      AudioChannelList.describe(detected, upTo: audioChannelCount))
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
