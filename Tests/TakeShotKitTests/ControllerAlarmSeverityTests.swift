import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// Which capture failure sticks in the alarm banner and which one toasts away,
/// stated once per message the pipeline can actually emit.
///
/// `ControllerCaptureTests` already samples the rule with four hand-written
/// strings. This suite is the whole inventory instead, because the rule is only
/// worth anything if it holds for every site: a take-loss message that lands in
/// the toast register is gone in five seconds, and the operator finds out in
/// the edit.
///
/// The `sticky` column IS the behaviour — it is what an operator sees. Rows may
/// be added when a new failure site appears, and the prose may be reworded, but
/// a value in that column changing means the alarm register of a real failure
/// moved, and that is a decision, never a refactor.
@Suite @MainActor struct ControllerAlarmSeverityTests {
    /// One `onError` call site in CaptureCore: where it lives, the message it
    /// builds (interpolations filled with representative values), and the
    /// register it has to land in.
    struct Sample: Sendable {
        let site: String
        let message: String
        let sticky: Bool
    }

    /// Every message CaptureCore hands to `onError`, in call-site order.
    ///
    /// Ten of the thirteen are sticky. The three that toast are the take's
    /// closing tallies, reported after a take that DID finalize: the live alarm
    /// for them, where there is one, already fired while the take was rolling,
    /// and these are the totals stated quietly afterwards.
    static let samples: [Sample] = [
        // CapturePipeline+Frame — the writer died mid-take
        .init(site: "Frame.appendToTake/writerFailed",
              message: "TAKE LOST — recording stopped, writer failed: "
                  + "The volume could not be found.",
              sticky: true),
        // CapturePipeline+Frame — sustained refusal that is not a death
        .init(site: "Frame.appendToTake/dropped",
              message: "Dropped 12 recording frame(s) "
                  + "— encoder/disk can't keep up",
              sticky: true),
        // CapturePipeline+PreRoll — the frames closest to the REC press
        .init(site: "PreRoll.drainPreRoll",
              message: "Pre-roll incomplete: 7 frame(s) "
                  + "before the REC point were not written",
              sticky: true),
        // CapturePipeline+Input — the camera changed format mid-shot
        .init(site: "Input.handleFormat",
              message: "Take closed: input format changed mid-take",
              sticky: true),
        // CapturePipeline+Input — the cable came out
        .init(site: "Input.signalLost",
              message: "Take closed: input signal lost mid-take",
              sticky: true),
        // CapturePipeline+Input — frames refused at the door
        .init(site: "Input.admitFrameAtIngress",
              message: "Pipeline overloaded — 100 frame(s) dropped at ingress",
              sticky: true),
        // CapturePipeline+ExternalAudio — the USB interface stopped feeding
        .init(site: "ExternalAudio.padGap",
              message: "USB AUDIO LOST — take continues, "
                  + "audio padded with silence",
              sticky: true),
        // CapturePipeline+Take — the writer never opened
        .init(site: "Take.beginTake",
              message: "Failed to start recording: "
                  + "You don’t have permission to save the file.",
              sticky: true),
        // CapturePipeline+Take — a take rolling before the audio format landed
        .init(site: "Take.warnIfTakeHasNoAudioTrack",
              message: "TAKE LOST audio — A001_T003.mov started before the "
                  + "audio format was known and has no audio track",
              sticky: true),
        // CapturePipeline+Take — the finalize threw; the file is _FAILED.mov
        .init(site: "Take.finishTake/finalizeFailed",
              message: "TAKE LOST — failed to finalize A001_T003_FAILED: "
                  + "The operation couldn’t be completed.",
              sticky: true),
        // CapturePipeline+Take — the closing tallies of a take that finalized
        .init(site: "Take.publish/droppedAudio",
              message: "Take A001_T003: 4 audio packet(s) dropped",
              sticky: false),
        .init(site: "Take.publish/gapFilledAudio",
              message: "Take A001_T003: 4 audio packet(s) gap-filled "
                  + "with silence",
              sticky: false),
        .init(site: "Take.publish/droppedVideo",
              message: "Take A001_T003: 9 video frame(s) dropped",
              sticky: false),
    ]

    /// Every message, one at a time, into an otherwise quiet controller.
    ///
    /// Both registers are cleared between rows because the sticky one does not
    /// clear itself: without that, row two would pass on row one's alarm.
    @Test func everyPipelineMessageLandsInTheRegisterItLandsInToday() async throws {
        try await ControllerHarness.run { controller, _ in
            let report = try #require(controller.pipeline.onError)
            for sample in Self.samples {
                controller.persistentAlert = nil
                controller.lastError = nil

                report(sample.message)

                if sample.sticky {
                    #expect(controller.persistentAlert == sample.message,
                            "\(sample.site) left the alarm banner empty")
                    #expect(controller.lastError == nil,
                            "\(sample.site) toasted a take-loss message")
                } else {
                    #expect(controller.lastError == sample.message,
                            "\(sample.site) said nothing at all")
                    #expect(controller.persistentAlert == nil,
                            "\(sample.site) raised a sticky alarm for a tally")
                }
            }
        }
    }

    /// A multicam channel prefixes its camera letter onto the message before it
    /// reaches the classifier, and that must not move a take-loss message out of
    /// the sticky register — a B-cam take is a take.
    @Test func aCameraLabelPrefixKeepsTheMessageInItsRegister() async throws {
        try await ControllerHarness.run { controller, _ in
            let report = try #require(controller.pipeline.onError)
            for sample in Self.samples {
                controller.persistentAlert = nil
                controller.lastError = nil

                let labelled = "B: \(sample.message)"
                report(labelled)

                #expect((controller.persistentAlert == labelled) == sample.sticky,
                        "\(sample.site) changed register when labelled")
                #expect((controller.lastError == labelled) == !sample.sticky,
                        "\(sample.site) changed register when labelled")
            }
        }
    }

    /// A clean REC start clears the banner — the one thing that does, besides
    /// the operator. Pinned here because the sticky register is only useful if
    /// something eventually takes it down.
    @Test func aStickyAlarmSurvivesUntilItIsCleared() async throws {
        try await ControllerHarness.run { controller, _ in
            let report = try #require(controller.pipeline.onError)
            report("Take closed: input signal lost mid-take")
            #expect(controller.persistentAlert != nil)

            // a toast on top does not take it down
            report("Take A001_T003: 4 audio packet(s) dropped")
            #expect(controller.persistentAlert != nil,
                    "a tally toast wiped a take-loss alarm")
            #expect(controller.lastError != nil)
        }
    }
}
