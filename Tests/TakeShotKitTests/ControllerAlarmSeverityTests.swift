import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// Which capture failure sticks in the alarm banner and which one toasts away,
/// stated once per message the pipeline can actually emit.
///
/// `ControllerCaptureTests` already samples the rule with four alarms. This
/// suite is the whole inventory instead, because the rule is only worth
/// anything if it holds for every site: a take-loss message that lands in the
/// toast register is gone in five seconds, and the operator finds out in the
/// edit.
///
/// The `sticky` column IS the behaviour — it is what an operator sees. Rows may
/// be added when a new failure site appears, and the prose may be reworded, but
/// a value in that column changing means the alarm register of a real failure
/// moved, and that is a decision, never a refactor.
///
/// The register used to be read off the prose, by matching English substrings
/// of the message. It is now carried on `PipelineAlarm.severity` and the words
/// are chosen separately. Both halves of that move are checked below: the
/// severities agree with what the old substring list said about the same
/// messages, and in English the localized wording is still the message
/// character for character.
@Suite @MainActor struct ControllerAlarmSeverityTests {
    /// One `onError` call site in CaptureCore: where it lives, the alarm it
    /// raises (interpolations filled with representative values), the English
    /// prose CaptureCore states for it, and the register it has to land in.
    struct Sample: Sendable {
        let site: String
        let alarm: PipelineAlarm
        let message: String
        let sticky: Bool
    }

    /// Every alarm CaptureCore can raise, in call-site order.
    ///
    /// Twelve of the fifteen are sticky. The three that toast are the take's
    /// closing tallies, reported after a take that DID finalize: the live alarm
    /// for them, where there is one, already fired while the take was rolling,
    /// and these are the totals stated quietly afterwards.
    static let samples: [Sample] = [
        // CapturePipeline+Frame — the writer died mid-take
        .init(site: "Frame.appendToTake/writerFailed",
              alarm: .takeLostWriterFailed(
                  reason: "The volume could not be found."),
              message: "TAKE LOST — recording stopped, writer failed: "
                  + "The volume could not be found.",
              sticky: true),
        // CapturePipeline+Frame — sustained refusal that is not a death
        .init(site: "Frame.appendToTake/dropped",
              alarm: .recordingFramesDropped(count: 12),
              message: "Dropped 12 recording frame(s) "
                  + "— encoder/disk can't keep up",
              sticky: true),
        // CapturePipeline+PreRoll — the frames closest to the REC press
        .init(site: "PreRoll.drainPreRoll",
              alarm: .preRollIncomplete(frames: 7),
              message: "Pre-roll incomplete: 7 frame(s) "
                  + "before the REC point were not written",
              sticky: true),
        // CapturePipeline+Input — the camera changed format mid-shot
        .init(site: "Input.handleFormat",
              alarm: .takeClosedFormatChanged,
              message: "Take closed: input format changed mid-take",
              sticky: true),
        // CapturePipeline+Input — the cable came out
        .init(site: "Input.signalLost",
              alarm: .takeClosedSignalLost,
              message: "Take closed: input signal lost mid-take",
              sticky: true),
        // CapturePipeline+FrameWatchdog — the board wedged and said nothing
        .init(site: "FrameWatchdog.checkFrameArrival",
              alarm: .takeClosedFramesStopped,
              message: "Take closed: input stopped delivering frames mid-take",
              sticky: true),
        // CapturePipeline+Input — frames refused at the door
        .init(site: "Input.admitFrameAtIngress",
              alarm: .ingressOverload(drops: 100),
              message: "Pipeline overloaded — 100 frame(s) dropped at ingress",
              sticky: true),
        // CapturePipeline+ExternalAudio — the USB interface stopped feeding
        .init(site: "ExternalAudio.padGap",
              alarm: .externalAudioPadded,
              message: "USB AUDIO LOST — take continues, "
                  + "audio padded with silence",
              sticky: true),
        // CapturePipeline+Audio — the source changed its own channel count
        .init(site: "Audio.conformedToTake",
              alarm: .takeAudioChannelsConformed(from: 2, to: 8),
              message: "AUDIO CHANNELS CHANGED — source sent 2, "
                  + "take conformed to 8",
              sticky: true),
        // CapturePipeline+Take — the writer never opened
        .init(site: "Take.beginTake",
              alarm: .recordingStartFailed(
                  reason: "You don’t have permission to save the file."),
              message: "Failed to start recording: "
                  + "You don’t have permission to save the file.",
              sticky: true),
        // CapturePipeline+Take — a take rolling before the audio format landed
        .init(site: "Take.warnIfTakeHasNoAudioTrack",
              alarm: .takeLostNoAudioTrack(file: "A001_T003.mov"),
              message: "TAKE LOST audio — A001_T003.mov started before the "
                  + "audio format was known and has no audio track",
              sticky: true),
        // CapturePipeline+Take — the finalize threw; the file is _FAILED.mov
        .init(site: "Take.finishTake/finalizeFailed",
              alarm: .takeLostFinalizeFailed(
                  file: "A001_T003_FAILED",
                  reason: "The operation couldn’t be completed."),
              message: "TAKE LOST — failed to finalize A001_T003_FAILED: "
                  + "The operation couldn’t be completed.",
              sticky: true),
        // CapturePipeline+Take — the closing tallies of a take that finalized
        .init(site: "Take.publish/droppedAudio",
              alarm: .takeDroppedAudioPackets(take: "A001_T003", count: 4),
              message: "Take A001_T003: 4 audio packet(s) dropped",
              sticky: false),
        .init(site: "Take.publish/gapFilledAudio",
              alarm: .takeGapFilledAudio(take: "A001_T003", count: 4),
              message: "Take A001_T003: 4 audio packet(s) gap-filled "
                  + "with silence",
              sticky: false),
        .init(site: "Take.publish/droppedVideo",
              alarm: .takeDroppedVideoFrames(take: "A001_T003", count: 9),
              message: "Take A001_T003: 9 video frame(s) dropped",
              sticky: false),
    ]

    /// Every alarm, one at a time, into an otherwise quiet controller.
    ///
    /// Both registers are cleared between rows because the sticky one does not
    /// clear itself: without that, row two would pass on row one's alarm.
    @Test func everyPipelineAlarmLandsInTheRegisterItLandsInToday() async throws {
        try await ControllerHarness.run { controller, _ in
            let report = try #require(controller.pipeline.onError)
            L10n.apply(.english)
            defer { L10n.apply(.english) }
            for sample in Self.samples {
                controller.persistentAlert = nil
                controller.lastError = nil

                report(sample.alarm)

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

    /// The classifier this replaced, kept verbatim as the oracle.
    ///
    /// It read the register off the message by matching these seven English
    /// substrings. The refactor's whole claim is that nothing moved, and this
    /// is what makes that claim checkable rather than asserted: the typed
    /// severity has to agree with the old list on every message the old list
    /// was ever shown.
    private static func legacyClassifierSaysSticky(_ message: String) -> Bool {
        let sticky = ["TAKE LOST", "AUDIO LOST", "Dropped", "ingress",
                      "Failed to start recording", "Take closed:",
                      "Pre-roll incomplete"]
        return sticky.contains(where: message.contains)
    }

    /// Sites added AFTER the substring classifier was retired. The oracle was
    /// never shown these messages, so agreeing with it about them is not a claim
    /// anybody made — and "AUDIO CHANNELS CHANGED" is precisely the shape that
    /// list could not classify: a sticky integrity alarm whose wording contains
    /// none of the seven magic words, which under the old rule would have
    /// toasted away in five seconds. Their severity is pinned by the row like
    /// every other one; only the oracle comparison is skipped.
    private static let afterTheClassifier: Set<String> = [
        "Audio.conformedToTake",
    ]

    @Test func theTypedSeverityAgreesWithTheSubstringListItReplaced() {
        for sample in Self.samples {
            #expect(sample.alarm.message == sample.message,
                    "\(sample.site): CaptureCore's English prose changed")
            if !Self.afterTheClassifier.contains(sample.site) {
                #expect(Self.legacyClassifierSaysSticky(sample.message)
                            == sample.sticky,
                        "\(sample.site): the oracle disagrees with the row")
            }
            #expect((sample.alarm.severity == .integrity) == sample.sticky,
                    "\(sample.site): the typed severity moved the register")
        }
    }

    /// An English operator must read exactly what they read before: the
    /// localized wording is the core's own message, character for character.
    /// Every one of the thirteen, so a translation cannot be smuggled into the
    /// base language.
    @Test func theEnglishWordingIsUnchangedByLocalizing() {
        L10n.apply(.english)
        defer { L10n.apply(.english) }
        for sample in Self.samples {
            #expect(sample.alarm.localizedText == sample.message,
                    "\(sample.site): the English text moved")
        }
    }

    /// …and a Russian operator gets Russian. A missing key renders as the key
    /// itself, which is how a half-translated alarm reaches a set.
    @Test func everyAlarmIsTranslated() {
        L10n.apply(.russian)
        defer { L10n.apply(.english) }
        for sample in Self.samples {
            let russian = sample.alarm.localizedText
            #expect(russian != sample.message,
                    "\(sample.site) is still English in the Russian bundle")
            #expect(!russian.hasPrefix("alarm_"),
                    "\(sample.site) rendered a raw key: \(russian)")
        }
    }

    /// A multicam channel's letter is put on by the controller, and that must
    /// not move a take-loss alarm out of the sticky register — a B-cam take is
    /// a take. Under the substring classifier the prefix was part of what got
    /// matched; now it is applied after the register is already decided.
    @Test func aCameraLabelPrefixKeepsTheAlarmInItsRegister() async throws {
        try await ControllerHarness.run { controller, _ in
            L10n.apply(.english)
            defer { L10n.apply(.english) }
            for sample in Self.samples {
                controller.persistentAlert = nil
                controller.lastError = nil

                controller.reportPipelineError(sample.alarm, camera: "B")

                let labelled = "B: \(sample.message)"
                #expect((controller.persistentAlert == labelled) == sample.sticky,
                        "\(sample.site) changed register when labelled")
                #expect((controller.lastError == labelled) == !sample.sticky,
                        "\(sample.site) changed register when labelled")
            }
        }
    }

    /// A clean REC start clears the banner — the one thing that does, besides
    /// the operator. Pinned here because the sticky register is only useful if
    /// something eventually takes it down, and only that.
    @Test func aStickyAlarmSurvivesUntilItIsCleared() async throws {
        try await ControllerHarness.run { controller, _ in
            let report = try #require(controller.pipeline.onError)
            report(.takeClosedSignalLost)
            #expect(controller.persistentAlert != nil)

            // a toast on top does not take it down
            report(.takeDroppedAudioPackets(take: "A001_T003", count: 4))
            #expect(controller.persistentAlert != nil,
                    "a tally toast wiped a take-loss alarm")
            #expect(controller.lastError != nil)
        }
    }

    /// The toast keys on the export, still, look and file-handling paths —
    /// localized separately from the alarms above, and with no severity
    /// question, since each is assigned straight to `lastError`.
    private static let toastKeys = [
        "toast_edl_failed", "toast_ale_failed", "toast_report_failed",
        "toast_pdf_render_failed", "toast_output_failed", "toast_grab_failed",
        "toast_grab_failed_reason", "toast_record_folder_recreated",
        "toast_lut_import_failed", "toast_lut_failed",
        "toast_metadata_log_not_saved", "toast_ranges_not_saved",
        "toast_delete_failed",
    ]

    /// Every toast key resolves in BOTH bundles, and this is load-bearing
    /// rather than tidy.
    ///
    /// A missing key renders as the key itself. The suites that check which
    /// toast was raised now compare against `L("toast_…")` instead of the
    /// English words — which is right, and which also means that a key absent
    /// from both files would make those checks compare the key to itself and
    /// pass while the operator reads `toast_delete_failed` on screen. The
    /// key-parity test cannot catch that: absent from both files IS parity.
    @Test func everyToastKeyResolvesInBothLanguages() {
        defer { L10n.apply(.english) }
        for language in [AppLanguage.english, .russian] {
            L10n.apply(language)
            for key in Self.toastKeys {
                let text = L(key)
                #expect(text != key,
                        "\(key) missing from \(language): the operator reads it")
                #expect(!text.hasPrefix("toast_"), "\(key) resolved to a key")
            }
        }
    }

    /// …and the Russian is actually Russian rather than a copy of the English.
    /// Two are deliberately identical — "EDL: %@" and "LUT: %@" are initialisms
    /// with a colon and nothing to translate — so they are named here rather
    /// than silently skipped.
    @Test func theToastsAreTranslatedExceptWhereThereIsNothingToTranslate() {
        defer { L10n.apply(.english) }
        let sameInBoth = Set(["toast_edl_failed", "toast_ale_failed",
                              "toast_lut_failed"])
        L10n.apply(.english)
        let english = Self.toastKeys.map { ($0, L($0)) }
        L10n.apply(.russian)
        for (key, englishText) in english where !sameInBoth.contains(key) {
            #expect(L(key) != englishText,
                    "\(key) is still English in the Russian bundle")
        }
        for key in sameInBoth {
            #expect(L(key) == english.first { $0.0 == key }?.1,
                    "\(key) gained a translation — take it out of sameInBoth")
        }
    }
}
