import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// The viewer's own state: what aspect the framelines have to hug, what arms
/// the compare, and what happens to a LUT selection whose file is not there any
/// more. The rendering itself needs a window and is not testable here; the
/// decisions in front of it are.
@Suite @MainActor struct ControllerViewerTests {
    @Test func theDisplayAspectFollowsTheSourceAndTheDesqueeze() async throws {
        try await ControllerHarness.run { controller, _ in
            // nothing known yet — 16:9 rather than a divide by zero
            let sixteenByNine: CGFloat = 16.0 / 9.0
            #expect(controller.displayAspect == sixteenByNine)

            controller.signalFormat = CaptureFormat(
                width: 1998, height: 1080, frameRate: 25, timecodeFPS: 25,
                name: "test")
            let flat: CGFloat = 1998.0 / 1080.0
            #expect(controller.displayAspect == flat)

            // playback wins while a clip is on screen
            controller.viewerMode = .playback
            controller.playbackAspect = 2.39
            #expect(controller.displayAspect == 2.39)

            // and the anamorphic stretch applies on top of whichever it is
            controller.assist.desqueeze = 2
            #expect(controller.displayAspect == 4.78)
        }
    }

    /// The desqueeze lives on the assist struct but has to survive a relaunch,
    /// so it is mirrored into settings — and a spherical lens stores nothing.
    @Test func theDesqueezeFactorIsMirroredIntoSettings() async throws {
        try await ControllerHarness.run { controller, _ in
            #expect(controller.settings.desqueezeFactor == nil)

            controller.assist.desqueeze = 1.33
            #expect(controller.settings.desqueezeFactor == 1.33)

            controller.assist.desqueeze = 1
            #expect(controller.settings.desqueezeFactor == nil)
        }
    }

    /// Coming out of a punch-in has to recentre: leaving the pan behind means
    /// the next punch-in starts off in a corner.
    @Test func leavingThePunchInRecentresThePan() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.togglePunchIn()
            #expect(controller.assist.punchIn == 2)

            controller.assist.panX = 0.3
            controller.assist.panY = -0.2
            controller.togglePunchIn()

            #expect(controller.assist.punchIn == 1)
            #expect(controller.assist.panX == 0)
            #expect(controller.assist.panY == 0)
        }
    }

    /// The rec/playback key drives the same property the segmented switch over
    /// the player is bound to, and it has to work in BOTH directions — a toggle
    /// that only goes one way strands the operator in playback with the camera
    /// rolling, which is the one place they cannot afford to be.
    @Test func theViewerModeKeySwitchesBothWays() async throws {
        try await ControllerHarness.run { controller, _ in
            #expect(controller.viewerMode == .record)

            controller.toggleViewerMode()
            #expect(controller.viewerMode == .playback)

            controller.toggleViewerMode()
            #expect(controller.viewerMode == .record)
        }
    }

    /// Unguarded on purpose, exactly like the switch it stands in for: an empty
    /// player is a state the viewer draws, and refusing the key with nothing
    /// loaded would leave the operator pressing it at a picture that never
    /// changes. What follows the switch is the routing its `didSet` does.
    @Test func theViewerModeKeyWorksWithNoClipLoaded() async throws {
        try await ControllerHarness.run { controller, _ in
            #expect(controller.playbackURL == nil)

            controller.toggleViewerMode()

            #expect(controller.viewerMode == .playback)
            #expect(!controller.isReviewingClip) // nothing to review, and it says so
        }
    }

    @Test func theScopesFlagFollowsEitherSurface() async throws {
        try await ControllerHarness.run { controller, _ in
            #expect(!controller.showScopes)
            controller.showScopesOverlay = true
            #expect(controller.showScopes)
            controller.showScopesOverlay = false
            controller.scopesWindowOpen = true
            #expect(controller.showScopes)
            controller.scopesWindowOpen = false
            #expect(!controller.showScopes)
        }
    }

    /// Picking a B-side clip means "compare these" — landing on it with the
    /// compare still off would show nothing at all.
    @Test func choosingACompareClipArmsTheWipe() async throws {
        try await ControllerHarness.run { controller, root in
            #expect(controller.compareMode == .off)

            controller.compareClipURL = root.appendingPathComponent("b.mov")
            #expect(controller.compareMode == .wipe)

            // an explicit mode the operator already chose is left alone
            controller.compareMode = .blend
            controller.compareClipURL = root.appendingPathComponent("c.mov")
            #expect(controller.compareMode == .blend)
        }
    }

    @Test func pinningAStillAsTheReferenceSwitchesToCompare() async throws {
        try await ControllerHarness.run { controller, root in
            let still = try ControllerFixtures.writePNG(
                at: root.appendingPathComponent("reference.png"))
            controller.viewerMode = .playback

            controller.pinReference(imageURL: still)

            #expect(controller.referencePinned)
            #expect(controller.compareMode == .wipe)
            // a pinned reference is compared against the LIVE picture
            #expect(controller.viewerMode == .record)
            #expect(controller.lastNotice == L("reference_pinned"))

            controller.unpinReference()
            #expect(!controller.referencePinned)
        }
    }

    @Test func aReferenceThatCannotBeReadIsReported() async throws {
        try await ControllerHarness.run { controller, root in
            controller.pinReference(
                imageURL: root.appendingPathComponent("not-an-image.png"))

            #expect(controller.lastError == L("reference_pin_failed"))
            #expect(!controller.referencePinned)
            #expect(controller.compareMode == .off)
        }
    }

    /// In playback the reference comes from the tap; with nothing loaded there
    /// is no frame to pin, and silently pinning nothing looked like the
    /// feature was broken.
    @Test func pinningWithNoFrameOnScreenIsReported() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.viewerMode = .playback

            controller.pinReferenceFromCurrentFrame()

            #expect(controller.lastError == L("reference_pin_failed"))
            #expect(!controller.referencePinned)
        }
    }

    @Test func theLUTMixIsClampedAndPersistedOnceTheDragSettles() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.lutIntensity = 1.8
            #expect(controller.lutIntensity == 1)
            controller.lutIntensity = -0.4
            #expect(controller.lutIntensity == 0)

            controller.lutIntensity = 0.35
            #expect(controller.live.lutIntensity == 0.35)
            // written once the drag stops, not on every tick
            await ControllerWait.until { controller.settings.lutIntensity == 0.35 }
            #expect(controller.settings.lutIntensity == 0.35)
        }
    }

    /// A LUT whose file has gone (moved, renamed, another machine) must not
    /// leave a dangling selection behind that silently does nothing.
    @Test func aMissingLUTFileClearsTheSelectionAndSaysSo() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.selectLUT(fileName: "no-such-look-\(UUID().uuidString).cube")

            #expect(controller.settings.lutFileName == nil)
            #expect(controller.currentCube == nil)
            #expect(controller.lastError?.hasPrefix("LUT:") == true)
            // picking a LUT means wanting to see it
            #expect(controller.settings.lutPreviewEnabled == true)
        }
    }

    /// A per-clip "LUT off" left over from an earlier take used to eat the
    /// next explicit enable — the LUT switch read as doing nothing.
    @Test func enablingThePreviewLUTClearsAPerClipSuppression() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.playbackLUTSuppressed = true

            controller.lutPreviewOn = true

            #expect(controller.settings.lutPreviewEnabled == true)
            #expect(!controller.playbackLUTSuppressed)
        }
    }
}
