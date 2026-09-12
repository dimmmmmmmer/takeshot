import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// **The checkbox that puts the reframe in the file** (owner: "и то и другое,
/// отдельной галкой").
///
/// What `SizingBakeTests` holds is the pipeline's half — that an armed take
/// really is reframed, latches, tags itself and reaches no measurement. This
/// is the operator's half: the switch reaches the assist the pipeline reads,
/// it says the right thing about the take it is about to make, and it is not
/// remembered — which is the one place it deliberately differs from the nine
/// controls above it in the same popover.
@Suite @MainActor struct ViewSizingBakeTests {
    /// The switch reaches the value the capture side reads, and starts off.
    @Test func theBakeSwitchReachesTheAssist() async throws {
        try await ControllerHarness.run { controller, _ in
            #expect(!controller.sizingRecordOn, "the bake was armed at launch")
            #expect(!controller.liveAssist.sizingRecord)
            controller.sizingRecordOn = true
            #expect(controller.liveAssist.sizingRecord,
                    "the checkbox never reached the assist")
            controller.sizingRecordOn = false
            #expect(!controller.liveAssist.sizingRecord)
        }
    }

    /// **It is not remembered, and the geometry beside it is.**
    ///
    /// A camera stays mounted the way it is mounted, so a flip is a crew
    /// convention and persists; "put it in the file" is a decision about
    /// today's deliverable and has to be made again. The chroma key's own bake
    /// is not persisted for the same reason, and a bake that came back armed
    /// after a relaunch is the one state a destructive switch must not reach
    /// quietly.
    @Test func theBakeSwitchIsNotRemembered() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.assist.flipH = true
            controller.sizingRecordOn = true
            // the flip is in the blob…
            #expect(controller.settings.assist.sizingFlipH == true)
            // …and nothing in it says the take is being reframed
            let blob = try? JSONEncoder().encode(controller.settings)
            let text = blob.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            #expect(!text.lowercased().contains("sizingrecord"),
                    "the bake was written into the settings blob")
        }
        // …so a fresh launch is unarmed, whatever was set last night
        try await ControllerHarness.run { controller, _ in
            #expect(!controller.sizingRecordOn)
        }
    }

    /// **The crop warning answers for the set the BAKE latches.**
    ///
    /// A take latches the live nine, so the notice has to read those. Asking
    /// the picture on screen instead would stay silent about a live punch-in
    /// while a take rolled under it — footage going permanently — and would
    /// raise a false alarm about a punch-in that exists only on a review
    /// picture and reaches no file at all.
    @Test func theCropWarningReadsTheSetTheBakeLatches() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.sizingRecordOn = true
            #expect(!controller.sizingBakeWillCrop, "nothing is cropping yet")

            // a live punch-in, seen from the review surface
            controller.assist.punchIn = 2
            controller.viewerMode = .playback
            controller.assist.playbackSizing = PictureSizing()
            #expect(controller.currentAssist.sizing.isCropping == false,
                    "the review picture is not cropped, so this proves nothing")
            #expect(controller.sizingBakeWillCrop,
                    "the notice went quiet about a live crop the take will make")

            // …and a punch-in that only exists under review raises nothing
            controller.assist.punchIn = 1
            var zoomed = PictureSizing()
            zoomed.zoom = 3
            controller.assist.playbackSizing = zoomed
            #expect(controller.currentAssist.sizing.isCropping)
            #expect(!controller.sizingBakeWillCrop,
                    "the notice warned about a crop no take will make")

            // …and with the bake off there is nothing to warn about at all
            controller.assist.punchIn = 2
            controller.assist.playbackSizing = nil
            controller.viewerMode = .record
            controller.sizingRecordOn = false
            #expect(!controller.sizingBakeWillCrop)
        }
    }

    /// **A reset under review keeps the lens.** The live reset keeps the
    /// desqueeze deliberately — it is the lens rather than a framing choice,
    /// and an anamorphic day is shot on one all day — and a reset that threw
    /// it away on the review surface would squeeze every clip opened
    /// afterwards, on the operator's screen, the director's monitor and the
    /// crew's phones alike, with no control that could put it back.
    @Test func aResetUnderReviewKeepsTheDesqueeze() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.assist.desqueeze = 2
            controller.viewerMode = .playback
            controller.punchInLevel = 3
            #expect(controller.currentAssist.sizing.zoom == 3)

            controller.resetSizing()

            #expect(controller.currentAssist.sizing.zoom == 1,
                    "the reset did not put the punch-in back")
            #expect(controller.currentAssist.sizing.width == 2,
                    "the reset threw the anamorphic desqueeze away")
        }
    }

    /// …and the reset LINK is lit only when pressing it would change
    /// something. It asked whether the picture had been moved at all, so a
    /// unit shooting anamorphic and nothing else had a lit link that did
    /// nothing, and went on being lit after they pressed it.
    @Test func theResetLinkIsLitOnlyWhenItWouldChangeSomething() async throws {
        try await ControllerHarness.run { controller, _ in
            #expect(!controller.canResetSizing, "lit over a neutral picture")
            controller.assist.desqueeze = 2
            #expect(!controller.canResetSizing,
                    "lit over a desqueeze the reset cannot clear")
            controller.assist.rotation = 12
            #expect(controller.canResetSizing)
            controller.resetSizing()
            #expect(!controller.canResetSizing,
                    "still lit after a reset that did everything it can")
        }
    }

    /// **The one field writes the number for the source that is selected.**
    ///
    /// An operator dials this in by ear, and they can only do that for the
    /// source they are listening to — so the field shows and writes that
    /// source's own number, and the other one is waiting when they switch.
    /// One control that wrote into one place would silently retune the source
    /// they are not on.
    @Test func theAudioOffsetFieldFollowsTheSelectedSource() async throws {
        try await ControllerHarness.run { controller, _ in
            #expect(controller.audioDelayMS == 0, "something was set at launch")
            controller.audioDelayMS = -18
            #expect(controller.settings.audio.embeddedDelayMS == -18)
            #expect(controller.settings.audio.externalDelayMS == nil,
                    "the embedded number was written into the external source")

            controller.audioInputUID = "cart"
            #expect(controller.audioDelayMS == 0,
                    "the new source inherited the other one's offset")
            controller.audioDelayMS = 42
            #expect(controller.settings.audio.externalDelayMS == 42)
            #expect(controller.settings.audio.embeddedDelayMS == -18,
                    "the embedded source lost its own number")

            // …and switching back gives the first one back, untouched
            controller.audioInputUID = nil
            #expect(controller.audioDelayMS == -18)

            // a number nobody could type here is brought back inside where
            // the operator can see it happen
            controller.audioDelayMS = 9_000
            #expect(controller.audioDelayMS
                == AudioSettings.delayRangeMS.upperBound)
            // …and zero stores nothing at all
            controller.audioDelayMS = 0
            #expect(controller.settings.audio.embeddedDelayMS == nil)
        }
    }

    /// Resetting the geometry leaves the switch where the operator put it.
    ///
    /// Not tidiness: an operator resets a frame in order to set another one,
    /// and re-arming the bake every time would be a click per setup. It costs
    /// nothing to leave armed — the pipeline never bakes an identity reframe
    /// (`CapturePipeline.bakesSizing`), so an armed switch over a neutral
    /// geometry writes the camera's own picture at the camera's own codes.
    @Test func resettingTheSizingLeavesTheBakeArmed() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.assist.rotation = 12
            controller.sizingRecordOn = true
            controller.resetSizing()
            #expect(controller.assist.sizing.isIdentity)
            #expect(controller.sizingRecordOn,
                    "a reset of the framing disarmed the bake")
        }
    }
}
