import Foundation

/// What the capture path reports when something goes wrong, as a value rather
/// than as prose.
///
/// The alarm register — a sticky banner or a five-second toast — used to be
/// decided in the app layer by matching English substrings of the message
/// ("TAKE LOST", "Dropped", "ingress", "Take closed:"). That made the wording
/// load-bearing: two unrelated questions, *how bad is this* and *what does it
/// say*, were answered by the same string. Two consequences, and the second is
/// the dangerous one. The messages could not be localized, so a Russian
/// operator read them in English; and localizing them anyway would have
/// silently demoted every take-loss alarm to a toast that scrolls away while
/// the operator is lighting the next setup, which is the difference between
/// knowing a take was lost and finding out in the edit.
///
/// So the severity travels WITH the event, and the classifier reads it instead
/// of guessing. Adding a case forces a severity to be declared — the compiler
/// asks, where a substring list simply failed to match and toasted.
///
/// `message` is the English prose this module states for itself: core errors
/// are deliberately not localized (see CLAUDE.md), and CaptureCore has no
/// access to the app's bundle. The operator-facing wording is chosen in the app
/// layer from the case and its values (`AlarmLocalization`), the same split
/// `ReportLocalization` already uses for the reports CaptureCore writes.
public enum PipelineAlarm: Sendable, Equatable {
    /// The writer refused a frame permanently — the volume went away, the disk
    /// filled, the encoder died. The take is closed where it stands.
    case takeLostWriterFailed(reason: String)
    /// Sustained refusal that is not a death: frames are being dropped from a
    /// take that is still recording.
    case recordingFramesDropped(count: Int)
    /// The pre-roll drain ran out of budget, so the frames closest to the
    /// camera's REC press — the whole point of pre-roll — never reached the
    /// file. Silence here reads as a clean head.
    case preRollIncomplete(frames: Int)
    /// The camera changed format mid-shot. The stream restart resets the PTS
    /// timeline, so the take is closed rather than left silently starving.
    case takeClosedFormatChanged
    /// The cable came out. No frames means no VANC, so the camera's stop and
    /// its next start are both invisible; the take is closed on the spot.
    case takeClosedSignalLost
    /// The input went quiet without reporting anything at all — a wedged board
    /// that stays listed and stops calling back. Same cost as a signal loss,
    /// and only a clock can see it (see `CapturePipeline+FrameWatchdog`).
    case takeClosedFramesStopped
    /// Frames turned away at the door because the in-flight window is full.
    case ingressOverload(drops: Int)
    /// The wire converter could not produce a frame — its buffer pools are
    /// exhausted, or the pixel format stopped being one it reads.
    ///
    /// **The one drop nothing could see.** It happens BEFORE the take path, so
    /// the frame never reaches the writer and none of the recording counters
    /// move; arrival is stamped at ingress, so the watchdog goes on believing
    /// frames are coming. REC stays red, the take stays open, and nothing at
    /// all is written to the file.
    case frameLostConversionFailed(count: Int)
    /// The USB audio interface stopped feeding while a take rolls. The take
    /// continues on padded silence — honest silence beats splicing sources
    /// into a writer whose channel count is already latched.
    case externalAudioPadded
    /// The take's audio track ran dry under the picture — the source declared
    /// channels and then delivered nothing to cover the span, so the writer
    /// filled it with silence rather than leave the input empty.
    ///
    /// Not a cosmetic difference: `movieFragmentInterval` releases a fragment
    /// only once EVERY input has data past the boundary, so an audio input with
    /// no data at all costs a crashed take the WHOLE file and not merely its
    /// sound (see `TakeWriter.padAudioIfNeeded`). Sticky, because the operator's
    /// take has no sound and the only other way to find that out is the edit.
    case takeAudioStarved
    /// The audio source changed its own channel count under a writer whose
    /// count is latched for the take. The packets are conformed to the latched
    /// count and the take survives; the map its later channels carry is a
    /// guess, which is why this is not a quiet notice.
    case takeAudioChannelsConformed(from: Int, to: Int)
    /// The writer never opened, so there is no take at all.
    case recordingStartFailed(reason: String)
    /// A take that began before the first audio packet has no audio input and
    /// discards every packet of the take. Silent scratch audio is only ever
    /// discovered in the edit.
    case takeLostNoAudioTrack(file: String)
    /// The finalize threw. The half-written file is renamed `*_FAILED.mov` so
    /// it cannot pass for good footage in the panel or in the log.
    case takeLostFinalizeFailed(file: String, reason: String)
    /// A finalized take's closing tally: audio packets that never made it.
    case takeDroppedAudioPackets(take: String, count: Int)
    /// A finalized take's closing tally: audio padded with silence.
    case takeGapFilledAudio(take: String, count: Int)
    /// A finalized take's closing tally: video frames that never made it.
    case takeDroppedVideoFrames(take: String, count: Int)

    /// How loudly the operator has to be told.
    ///
    /// Deliberately not named for the widget that shows it: the pipeline knows
    /// what a failure COSTS, and the app decides what that looks like on
    /// screen (today: a sticky banner and a five-second toast).
    public enum Severity: Sendable, Equatable {
        /// Footage is gone, or the take now rolling is at risk. It has to stay
        /// on screen until somebody deals with it.
        case integrity
        /// Worth saying once.
        case notice
    }

    /// One `switch`, two answers — so a new case cannot be added without
    /// stating which side of the line it falls on.
    ///
    /// The three tallies are the only notices, and they are notices because
    /// they arrive AFTER a take that finalized successfully: whatever live
    /// alarm they had (dropped frames, padded audio) already fired in the
    /// integrity register while the take was rolling, and this is the total
    /// stated quietly afterwards. Everything else costs footage.
    public var severity: Severity {
        switch self {
        case .takeLostWriterFailed, .recordingFramesDropped, .preRollIncomplete,
             .takeClosedFormatChanged, .takeClosedSignalLost,
             .takeClosedFramesStopped, .ingressOverload,
             .externalAudioPadded, .takeAudioStarved,
             .takeAudioChannelsConformed,
             .recordingStartFailed,
             .takeLostNoAudioTrack, .takeLostFinalizeFailed,
             .frameLostConversionFailed:
            .integrity
        case .takeDroppedAudioPackets, .takeGapFilledAudio,
             .takeDroppedVideoFrames:
            .notice
        }
    }

    /// The event in English, which is what a core-level consumer and this
    /// module's own tests read. The app shows the localized wording instead —
    /// see `AlarmLocalization`.
    public var message: String {
        switch self {
        case .takeLostWriterFailed(let reason):
            "TAKE LOST — recording stopped, writer failed: \(reason)"
        case .recordingFramesDropped(let count):
            "Dropped \(count) recording frame(s) — encoder/disk can't keep up"
        case .preRollIncomplete(let frames):
            "Pre-roll incomplete: \(frames) frame(s) "
                + "before the REC point were not written"
        case .takeClosedFormatChanged:
            "Take closed: input format changed mid-take"
        case .takeClosedSignalLost:
            "Take closed: input signal lost mid-take"
        case .takeClosedFramesStopped:
            "Take closed: input stopped delivering frames mid-take"
        case .frameLostConversionFailed(let count):
            "TAKE AT RISK — \(count) frame(s) never converted; nothing is reaching the file"
        case .ingressOverload(let drops):
            "Pipeline overloaded — \(drops) frame(s) dropped at ingress"
        case .externalAudioPadded:
            "USB AUDIO LOST — take continues, audio padded with silence"
        case .takeAudioStarved:
            "AUDIO LOST — the take's audio track starved, padded with silence"
        case .takeAudioChannelsConformed(let from, let to):
            "AUDIO CHANNELS CHANGED — source sent \(from), "
                + "take conformed to \(to)"
        case .recordingStartFailed(let reason):
            "Failed to start recording: \(reason)"
        case .takeLostNoAudioTrack(let file):
            "TAKE LOST audio — \(file) started before the audio format "
                + "was known and has no audio track"
        case .takeLostFinalizeFailed(let file, let reason):
            "TAKE LOST — failed to finalize \(file): \(reason)"
        case .takeDroppedAudioPackets(let take, let count):
            "Take \(take): \(count) audio packet(s) dropped"
        case .takeGapFilledAudio(let take, let count):
            "Take \(take): \(count) audio packet(s) gap-filled with silence"
        case .takeDroppedVideoFrames(let take, let count):
            "Take \(take): \(count) video frame(s) dropped"
        }
    }
}
