import CaptureCore
import Foundation

// The bridge between the app's language switch and the failures CaptureCore
// reports, and the companion of `ReportLocalization` — same reason, same shape.
// CaptureCore is deliberately localization-free (it states each alarm in
// English on `PipelineAlarm.message`, which is what its own tests and any
// core-level consumer read); the words the operator sees are chosen here,
// through `L()`, at the moment the alarm is raised. That is what makes an
// alarm follow the language the app is set to right then.
//
// The severity is NOT decided here. It rides on the alarm — see
// `PipelineAlarm.severity` — precisely so that rewording a line, or
// translating it, cannot move a lost take out of the sticky register.

extension PipelineAlarm {
    /// The alarm in the operator's language.
    ///
    /// The two `reason` values are already localized by the system before they
    /// reach us (`Error.localizedDescription`, `TakeWriter.failureReason`), so
    /// a Russian operator gets a Russian sentence inside a Russian frame — this
    /// used to be an English frame around a Russian middle.
    var localizedText: String {
        switch self {
        case .takeLostWriterFailed(let reason):
            L("alarm_take_lost_writer", reason)
        case .recordingFramesDropped(let count):
            L("alarm_frames_dropped", count)
        case .preRollIncomplete(let frames):
            L("alarm_preroll_incomplete", frames)
        case .takeClosedFormatChanged:
            L("alarm_take_closed_format")
        case .takeClosedSignalLost:
            L("alarm_take_closed_signal")
        case .takeClosedFramesStopped:
            L("alarm_take_closed_no_frames")
        case .ingressOverload(let drops):
            L("alarm_ingress_overload", drops)
        case .externalAudioPadded:
            L("alarm_usb_audio_lost")
        case .takeAudioStarved:
            L("alarm_take_audio_starved")
        case .takeAudioChannelsConformed(let from, let to):
            L("alarm_audio_channels_conformed", from, to)
        case .recordingStartFailed(let reason):
            L("alarm_recording_start_failed", reason)
        case .takeLostNoAudioTrack(let file):
            L("alarm_take_lost_no_audio", file)
        case .takeLostFinalizeFailed(let file, let reason):
            L("alarm_take_lost_finalize", file, reason)
        case .takeDroppedAudioPackets(let take, let count):
            L("alarm_take_audio_dropped", take, count)
        case .takeGapFilledAudio(let take, let count):
            L("alarm_take_audio_gap_filled", take, count)
        case .takeDroppedVideoFrames(let take, let count):
            L("alarm_take_video_dropped", take, count)
        }
    }
}
