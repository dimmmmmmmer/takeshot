import CaptureCore
import Foundation
import SwiftUI
import Testing

@testable import TakeShotKit

/// **The nine sizing controls, reachable at last.**
///
/// `PictureSizing` has understood all nine since it existed and the app could
/// set four; the other five were a capability the renderer had and nothing
/// could reach. What has to hold is that the popover's writes land on the
/// picture, that they survive a relaunch the way a crew convention should, and
/// that a stored value nobody typed here cannot put the frame somewhere
/// invisible.
@Suite @MainActor struct ViewSizingMenuTests {
    /// **Every control reaches the transform.** The renderer reads
    /// `ViewAssist.sizing` and nothing else, so a field that does not arrive
    /// there is a control that does nothing.
    @Test func everyControlReachesTheTransform() {
        var assist = ViewAssist()
        assist.desqueeze = 2
        assist.height = 1.5
        assist.punchIn = 1.25
        assist.panX = 0.1
        assist.panY = -0.2
        assist.rotation = 12
        assist.pitch = -4
        assist.yaw = 7
        assist.flipH = true
        assist.flipV = true
        let sizing = assist.sizing
        #expect(sizing.width == 2)
        #expect(sizing.height == 1.5)
        #expect(sizing.zoom == 1.25)
        #expect(sizing.panX == 0.1)
        #expect(sizing.panY == -0.2)
        #expect(sizing.rotation == 12)
        #expect(sizing.pitch == -4)
        #expect(sizing.yaw == 7)
        #expect(sizing.flipH)
        #expect(sizing.flipV)
    }

    /// A fresh assist is the transform this app has always applied, which is
    /// what makes the five new fields free: the renderer's fast paths key off
    /// `isIdentity`.
    @Test func aFreshAssistIsStillTheIdentity() {
        #expect(ViewAssist().sizing.isIdentity)
        var rotated = ViewAssist()
        rotated.rotation = 1
        #expect(!rotated.sizing.isIdentity)
    }

    /// **They persist like a crew convention**, because they are one: a camera
    /// mounted upside down is flipped once, not once a day.
    @Test func theSizingSurvivesARelaunch() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.assist.rotation = 12.5
            controller.assist.height = 1.25
            controller.assist.flipH = true
            #expect(controller.settings.assist.sizingRotation == 12.5)
            #expect(controller.settings.assist.sizingHeight == 1.25)
            #expect(controller.settings.assist.sizingFlipH == true)
            // …and neutral writes nothing at all, so a blob from a build
            // without these keys is what a neutral set produces
            controller.assist.rotation = 0
            controller.assist.height = 1
            controller.assist.flipH = false
            #expect(controller.settings.assist.sizingRotation == nil)
            #expect(controller.settings.assist.sizingHeight == nil)
            #expect(controller.settings.assist.sizingFlipH == nil)
        }
    }

    /// **…and it is on screen at launch**, which is the other half of the
    /// round trip: a set of numbers written to the blob and never read back is
    /// a convention the operator sets every morning.
    @Test func theStoredSizingIsOnScreenAtLaunch() async throws {
        let stored: (inout CaptureSettings) -> Void = { settings in
            settings.assist.sizingRotation = 12.5
            settings.assist.sizingHeight = 1.25
            settings.assist.sizingFlipV = true
            // …and a value nobody could have typed here, from a hand edit
            settings.assist.sizingYaw = 400
        }
        try await ControllerHarness.run(configure: stored) { controller, _ in
            #expect(controller.assist.rotation == 12.5)
            #expect(controller.assist.height == 1.25)
            #expect(controller.assist.flipV)
            #expect(controller.assist.yaw
                == SizingControlsPanel.tiltRange.upperBound,
                "a hand-edited blob reached the picture unclamped")
        }
    }

    /// A hand-edited blob must not put the picture somewhere nobody can see
    /// it, and the clamps are the same ones the popover's sliders offer.
    @Test func aStoredValueIsClampedToWhatThePanelCanAskFor() {
        var settings = AssistSettings()
        settings.sizingHeight = 40
        settings.sizingRotation = 4_000
        settings.sizingPitch = -90
        settings.sizingYaw = 90
        #expect(settings.sizingHeightEffective
            == SizingControlsPanel.heightRange.upperBound)
        #expect(settings.sizingRotationEffective
            == SizingControlsPanel.rotationRange.upperBound)
        #expect(settings.sizingPitchEffective
            == SizingControlsPanel.tiltRange.lowerBound)
        #expect(settings.sizingYawEffective
            == SizingControlsPanel.tiltRange.upperBound)
        // …and nothing stored is neutral
        let fresh = AssistSettings()
        #expect(fresh.sizingHeightEffective == 1)
        #expect(fresh.sizingRotationEffective == 0)
    }

    /// **Reset puts the picture back and leaves the aids alone.** An operator
    /// who has spent a minute levelling a horizon must not lose it by
    /// switching false colour off, and the reverse holds here.
    @Test func resettingTheSizingLeavesTheAidsAlone() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.assist.rotation = 12
            controller.assist.punchIn = 2
            controller.assist.flipV = true
            controller.assist.zebraOn = true
            controller.assist.colorTool = .falseColor

            controller.resetSizing()

            #expect(controller.assist.sizing.isIdentity,
                    "\(controller.assist.sizing)")
            #expect(controller.assist.zebraOn, "the reset took an aid with it")
            #expect(controller.assist.colorTool == .falseColor)
        }
    }

    /// The desqueeze is NOT one of them: it is `width` under its own older
    /// name, with its own switch and its own remembered factor, and a reset of
    /// the geometry must not throw away the 2x an anamorphic day is shot on.
    @Test func resettingTheSizingKeepsTheDesqueeze() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.assist.desqueeze = 2
            controller.assist.rotation = 12
            controller.resetSizing()
            #expect(controller.assist.desqueeze == 2)
            #expect(controller.assist.rotation == 0)
        }
    }

    /// The badge marks a picture that has been moved, the way the look's badge
    /// marks a live look.
    @Test func theBadgeKnowsWhenThePictureHasBeenMoved() async throws {
        try await ControllerHarness.run { controller, _ in
            #expect(controller.liveAssist.sizing.isIdentity)
            controller.assist.yaw = 3
            await ControllerWait.untilWritten {
                !controller.liveAssist.sizing.isIdentity
            }
            #expect(!controller.liveAssist.sizing.isIdentity)
            #expect(!controller.liveAssist.sizing.isAffine,
                    "a yaw is one of the two terms that are not affine")
        }
    }
    // MARK: - two sets, one for each surface

    /// **A punch-in taken during review does not move the camera's picture.**
    ///
    /// That is the whole point of two sets: the live geometry is what the SDI
    /// output and the director's monitor are showing, and an operator checking
    /// focus on a take must not move it.
    @Test func punchingInDuringPlaybackLeavesTheLiveSetAlone() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.viewerMode = .playback
            controller.punchInLevel = 3

            #expect(controller.currentAssist.punchIn == 3)
            #expect(controller.liveAssist.forLive.punchIn == 1,
                    "the live picture moved with the review")
            // …and switching back shows the camera's own geometry again
            controller.viewerMode = .record
            #expect(controller.currentAssist.punchIn == 1)
        }
    }

    /// …and the reverse: the camera's own geometry is not what a take is
    /// reviewed through once the two have been set apart.
    @Test func theTwoSetsAreIndependentInBothDirections() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.viewerMode = .record
            controller.punchInLevel = 2
            controller.viewerMode = .playback
            controller.punchInLevel = 4
            #expect(controller.currentAssist.punchIn == 4)
            controller.viewerMode = .record
            #expect(controller.currentAssist.punchIn == 2)
        }
    }

    /// **Until they are set apart they are one set**, so a unit that never
    /// touches this sees exactly what the app has always shown — including
    /// the desqueeze, which is a property of the LENS and belongs on both.
    @Test func playbackStartsOutSharingTheLiveGeometry() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.assist.desqueeze = 2
            controller.assist.rotation = 5
            controller.viewerMode = .playback
            #expect(controller.currentAssist.desqueeze == 2)
            #expect(controller.currentAssist.rotation == 5)
            #expect(controller.assist.playbackSizing == nil,
                    "a shared set should not have been split")
        }
    }

    /// **The aids are ONE set and stay one.** False colour is a way of
    /// looking, not a property of a surface: an operator who turns it on while
    /// reviewing expects it on the live picture too.
    @Test func theAidsAreSharedWhileTheGeometryIsNot() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.viewerMode = .playback
            controller.punchInLevel = 3
            // **Committed first, deliberately.** A gesture drafts and folds in
            // 250 ms later, and a direct write to `assist` supersedes a draft
            // that has not folded yet — which is the documented rule and not
            // this feature's business. On set the two are seconds apart.
            controller.commitAssistDraft()
            controller.assist.zebraOn = true
            #expect(controller.liveAssist.forLive.zebraOn,
                    "an aid switched on in playback did not reach the live view")
            #expect(controller.liveAssist.forPlayback.zebraOn)
            #expect(controller.liveAssist.forLive.punchIn == 1)
            #expect(controller.liveAssist.forPlayback.punchIn == 3)
        }
    }

    /// **What each SURFACE actually received**, which is a different question
    /// from what the controller holds — and the one that matters, because the
    /// push is where the two sets reach the picture.
    @Test func eachSurfaceIsGivenItsOwnGeometry() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.viewerMode = .playback
            controller.punchInLevel = 3
            controller.commitAssistDraft()

            #expect(controller.playbackTap.assistStage.currentAssist.punchIn == 3,
                    "the playback surface did not get the review's punch-in")
            #expect(controller.pipeline.assistStage.currentAssist.punchIn == 1,
                    "the camera's surface got the review's punch-in")
            // …and neither was handed a set for somebody else
            #expect(controller.pipeline.assistStage.currentAssist
                .playbackSizing == nil)
            #expect(controller.playbackTap.assistStage.currentAssist
                .playbackSizing == nil)
        }
    }

    /// **No surface is ever handed the pair.** That is what keeps a value
    /// carrying two transforms safe: the only ways out each describe exactly
    /// one surface, and neither carries a set for somebody else.
    @Test func neitherSurfaceIsHandedTheOtherSet() {
        var assist = ViewAssist()
        assist.punchIn = 2
        var playback = PictureSizing()
        playback.zoom = 4
        assist.playbackSizing = playback
        #expect(assist.forLive.playbackSizing == nil)
        #expect(assist.forPlayback.playbackSizing == nil)
        #expect(assist.forLive.punchIn == 2)
        #expect(assist.forPlayback.punchIn == 4)
    }

    /// A reset pressed while reviewing must not straighten the camera's own
    /// picture on the SDI output.
    @Test func resettingInPlaybackLeavesTheLiveGeometryAlone() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.assist.rotation = 12
            controller.viewerMode = .playback
            controller.punchInLevel = 3

            controller.resetSizing()

            #expect(controller.currentAssist.sizing.isIdentity)
            controller.viewerMode = .record
            #expect(controller.currentAssist.rotation == 12,
                    "the reset reached the live set from playback")
        }
    }

    /// The scopes measure what the VIEWER shows: with a playback geometry of
    /// its own, the live set is about a different picture.
    @Test func theScopesFollowTheSurfaceOnScreen() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.viewerMode = .playback
            controller.punchInLevel = 4
            let reviewing = controller.scopeRegion
            #expect(abs(reviewing.width - 0.25) < 0.001,
                    "\(reviewing) is not a quarter of the frame")
            controller.viewerMode = .record
            #expect(abs(controller.scopeRegion.width - 1) < 0.001,
                    "the live scopes inherited the review's punch-in")
        }
    }

}
