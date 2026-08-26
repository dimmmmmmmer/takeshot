import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// The half of the channel decision the operator can see and take back.
///
/// A mask chosen by measurement that cannot be seen is a mask nobody can trust,
/// and "nobody can trust it" is not a UI complaint here — it is the operator
/// deciding, on a shooting day, not to rely on the audio at all. So the panel
/// has to say who chose, and one click has to be enough to disagree.
@Suite @MainActor struct ControllerAudioChannelAutoTests {
    /// A fresh install follows the measurement, without anyone switching
    /// anything on. That is what makes it the DEFAULT rather than a feature.
    @Test func aFreshInstallFollowsTheMeasurement() async throws {
        try await ControllerHarness.run { controller, _ in
            #expect(controller.settings.audio.audioChannelAuto == nil)
            #expect(controller.isAudioChannelsAutomatic)
            // …and with nothing measured yet it records everything, exactly as
            // this app did before the measurement existed
            #expect(controller.effectiveAudioChannelMask == nil)
            #expect(controller.isChannelEnabled(15))

            controller.detectedAudioChannelMask = 0b11

            #expect(controller.effectiveAudioChannelMask == 0b11)
            #expect(controller.isChannelEnabled(0))
            #expect(controller.isChannelEnabled(1))
            #expect(!controller.isChannelEnabled(2),
                    "a channel nothing was measured on is still being recorded")
        }
    }

    /// Clicking a channel is the operator taking the decision — and it starts
    /// from the mask IN FORCE.
    ///
    /// This is the one an obvious implementation gets wrong. Starting from a
    /// fixed 0xFFFF, a first click on channel 3 would produce 0xFFF7: the
    /// fourteen silent channels the measurement had just excluded all switch
    /// back ON behind the operator's back, which is the original bug arriving
    /// through the control that was supposed to fix it.
    @Test func aClickStartsFromTheChannelsTheMeasurementChose() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.detectedAudioChannelMask = 0b11
            try #require(controller.isAudioChannelsAutomatic)

            controller.toggleAudioChannel(2) // add the first ISO

            let mask: Int? = controller.settings.audio.audioChannelMask
            #expect(mask == 0b111, "the click widened to \(mask as Any)")
            #expect(controller.settings.audio.audioChannelAuto == false)
            #expect(!controller.isAudioChannelsAutomatic)
            #expect(!controller.isChannelEnabled(15))
        }
    }

    /// …and the measurement stops answering once they have. Auto fills the nil;
    /// it never overrides.
    @Test func theMeasurementDoesNotMoveAMaskTheOperatorChose() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.toggleAudioChannel(0) // anything, to take the decision
            let chosen: Int? = controller.settings.audio.audioChannelMask

            controller.detectedAudioChannelMask = 0b11

            #expect(controller.effectiveAudioChannelMask == chosen,
                    "the measurement moved a hand-picked mask")
        }
    }

    /// Handing it back. The stored mask has to go with it — auto fills the nil,
    /// so a mask left behind would keep answering and the switch would look
    /// broken.
    @Test func theOperatorCanHandTheDecisionBack() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.detectedAudioChannelMask = 0b11
            controller.toggleAudioChannel(2)
            try #require(!controller.isAudioChannelsAutomatic)

            controller.setAudioChannelsAuto(true)

            #expect(controller.isAudioChannelsAutomatic)
            #expect(controller.settings.audio.audioChannelMask == nil,
                    "the old mask stayed behind and kept answering")
            #expect(controller.effectiveAudioChannelMask == 0b11)
        }
    }

    /// Switching it OFF changes who decides, not what is recorded: what auto had
    /// chosen is written down as the operator's own mask.
    ///
    /// The alternative — clearing the mask on the way out — would silently widen
    /// the next take from two channels to sixteen at the moment the operator
    /// said "I will take it from here", which is the opposite of what they said.
    @Test func switchingItOffKeepsRecordingTheSameChannels() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.detectedAudioChannelMask = 0b11
            try #require(controller.effectiveAudioChannelMask == 0b11)

            controller.setAudioChannelsAuto(false)

            #expect(controller.settings.audio.audioChannelAuto == false)
            #expect(controller.effectiveAudioChannelMask == 0b11)
            #expect(controller.settings.audio.audioChannelMask == 0b11)
        }
    }

    /// Switching it off with nothing measured yet stores no mask at all — every
    /// declared channel, which is exactly today's behaviour and the state an
    /// operator who wants all sixteen is asking for.
    @Test func switchingItOffWithNothingMeasuredRecordsEverything() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.setAudioChannelsAuto(false)

            #expect(controller.settings.audio.audioChannelMask == nil)
            #expect(controller.effectiveAudioChannelMask == nil)
            #expect(controller.isChannelEnabled(15))
            #expect(!controller.isAudioChannelsAutomatic,
                    "'all channels, my choice' collapsed back into 'auto'")
        }
    }

    /// The mask is latched per take and the writer's channel count is fixed with
    /// it, so neither control moves under a rolling take — the rule is on the
    /// controller (`canChangeAudioChannels`) rather than at the two surfaces
    /// that enforce it.
    @Test func neitherControlMovesTheMaskUnderARollingTake() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.detectedAudioChannelMask = 0b11
            controller.isRecording = true
            #expect(!controller.canChangeAudioChannels)

            controller.toggleAudioChannel(2)
            controller.setAudioChannelsAuto(false)

            #expect(controller.settings.audio.audioChannelMask == nil,
                    "the channel mask moved under a rolling take")
            #expect(controller.isAudioChannelsAutomatic)

            controller.isRecording = false
            controller.toggleAudioChannel(2)
            #expect(controller.settings.audio.audioChannelMask == 0b111,
                    "…and it still works once the take is closed")
        }
    }

    /// The mix key round-trips back into auto. Without remembering the auto
    /// flag, one press of it would have been a one-way door out of the
    /// measurement for the rest of the session.
    @Test func theMixKeyComesBackToTheMeasurement() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.detectedAudioChannelMask = 0b1111
            try #require(controller.isAudioChannelsAutomatic)

            controller.toggleAudioChannelBank()
            #expect(controller.isRecordingMixOnly)
            #expect(!controller.isAudioChannelsAutomatic)

            controller.toggleAudioChannelBank()

            #expect(controller.isAudioChannelsAutomatic,
                    "the mix key left the measurement switched off")
            #expect(controller.effectiveAudioChannelMask == 0b1111)
        }
    }

    /// …and it is a no-op when the measurement has already chosen the mix pair,
    /// which it does on every stereo embed. `isRecordingMixOnly` reads what is
    /// IN FORCE rather than what is stored, or the key would offer to switch to
    /// the state it is already in.
    @Test func theMixKeyReadsTheMaskInForce() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.detectedAudioChannelMask = CaptureController.mixChannelMask

            #expect(controller.isRecordingMixOnly,
                    "auto had chosen 1-2 and the mix key did not know")
        }
    }

    /// What the panel actually says, in all four states. The wording is not the
    /// point; that there ARE four is.
    ///
    /// "auto, nothing measured yet" is the state the first second of every
    /// session is in, and it records every channel — an operator told only
    /// "auto" while looking at sixteen lit meters would read that as broken.
    @Test func thePanelSaysWhoChoseTheChannels() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.audioChannelCount = 16
            let listening: String = controller.audioChannelDecisionText

            controller.detectedAudioChannelMask = 0b11
            let measured: String = controller.audioChannelDecisionText

            controller.toggleAudioChannel(2)
            let byHand: String = controller.audioChannelDecisionText

            controller.setAudioChannelsAuto(true)
            controller.setAudioChannelsAuto(false)
            controller.settings.audio.audioChannelMask = nil
            let everything: String = controller.audioChannelDecisionText

            // …and the fifth reading this one has to be told apart from: a
            // measurement that really did find every channel carrying. A
            // "listening" line that quietly says "1-16 carry signal" is the
            // app claiming a measurement it has not made, and it is the exact
            // shape the obvious implementation takes (`detected ?? 0xFFFF`).
            controller.setAudioChannelsAuto(true)
            controller.detectedAudioChannelMask = 0xFFFF
            let allMeasured: String = controller.audioChannelDecisionText

            let states: [String] = [listening, measured, byHand, everything,
                                    allMeasured]
            let joined: String = states.joined(separator: " | ")
            #expect(Set(states).count == 5,
                    "two of the five channel states read the same: \(joined)")
            #expect(listening != allMeasured,
                    "nothing was measured, yet the panel read: \(listening)")
            #expect(measured.contains("1-2"), "measured reads: \(measured)")
            #expect(byHand.contains("1-3"), "by hand reads: \(byHand)")
            #expect(!listening.isEmpty)
            #expect(!everything.isEmpty)
        }
    }

    /// A settings file written before any of this existed still decodes, and
    /// still records the channels it was written to record.
    ///
    /// Two halves, and the second is the one that matters: an operator who had
    /// already picked channels must not have them quietly replaced by a
    /// measurement on the day they upgrade.
    @Test func aSettingsFileWrittenBeforeThisStillDecodes() throws {
        let json = """
            {"schemaVersion":\(CaptureSettings.currentSchemaVersion),
             "audioChannelMask":15,"codec":"ProRes 422 HQ",
             "cameraLabel":"A","destinationPath":"/tmp",
             "detectionMode":"vanc","namingTemplate":"{tc}",
             "projectName":"Old","startDebounceFrames":3,
             "stopDebounceFrames":3}
            """
        let data: Data = try #require(json.data(using: .utf8))
        let settings: CaptureSettings =
            try JSONDecoder().decode(CaptureSettings.self, from: data)

        #expect(settings.audio.audioChannelAuto == nil,
                "the missing key did not read as the default")
        #expect(settings.audio.audioChannelMask == 15,
                "the operator's own channel selection was lost on upgrade")
    }

    /// The bundle says who chose, in three states rather than two — a reader of
    /// a diagnostics bundle has to be able to tell a two-channel take that was
    /// measured from one that was asked for.
    @Test func theBundleSaysWhoChoseTheChannels() {
        #expect(CaptureController.channelDecision(automatic: false, measured: true)
            == "operator")
        #expect(CaptureController.channelDecision(automatic: true, measured: true)
            != CaptureController.channelDecision(automatic: true, measured: false))
        #expect(CaptureController.channelDecision(automatic: true, measured: false)
            .contains("all channels"))
    }
}

/// The channel list as an operator reads it. One-based, and runs collapse.
@Suite struct AudioChannelListTests {
    @Test func aMaskReadsAsOneBasedRunsOfChannels() {
        #expect(AudioChannelList.describe(0b11, upTo: 16) == "1-2")
        #expect(AudioChannelList.describe(0b1, upTo: 16) == "1")
        #expect(AudioChannelList.describe(0b11110011, upTo: 16) == "1-2, 5-8")
        #expect(AudioChannelList.describe(0b10101, upTo: 16) == "1, 3, 5")
        #expect(AudioChannelList.describe(0xFFFF, upTo: 16) == "1-16")
        #expect(AudioChannelList.describe(0, upTo: 16).isEmpty)
    }

    /// A line that named channels the meters do not show would be worse than no
    /// line: masks are stored sixteen bits wide whatever the source delivers, so
    /// a two-channel cart under a stale 1-8 mask must still read as "1-2".
    @Test func itNeverNamesAChannelTheSourceDoesNotHave() {
        #expect(AudioChannelList.describe(0xFF, upTo: 2) == "1-2")
        // …and an unknown count falls back to the sixteen the bridge declares
        #expect(AudioChannelList.describe(0xFFFF, upTo: 0) == "1-16")
    }
}
