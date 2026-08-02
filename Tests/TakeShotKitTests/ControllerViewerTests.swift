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

    /// Owner item 24b. The A pane of the A/B split follows the compare SOURCE,
    /// not the viewer mode: picking another clip and switching to A/B used to
    /// leave the left half on the camera, i.e. showing the operator the one
    /// comparison they had just turned off. `PreviewView` reads this property, so
    /// the decision is asserted where it is made.
    @Test func theABPaneFollowsTheChosenCompareSource() async throws {
        try await ControllerHarness.run { controller, root in
            controller.viewerMode = .playback
            #expect(controller.comparePaneSource == .live)

            controller.compareClipURL = root.appendingPathComponent("b.mov")
            controller.compareMode = .sideBySide
            #expect(controller.comparePaneSource == .clip,
                    "A/B against a clip is still showing live")

            controller.compareClipURL = nil
            #expect(controller.comparePaneSource == .live)
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

    /// Difference reaches the render as ONE compositor mode carrying the
    /// dialled gain. The mapping is written once in `compareComposite`, and
    /// "a fourth mode forgotten in the translation" is the exact bug that
    /// single spelling exists to prevent — asserted here for the mode that
    /// was added fourth, and re-checked when the gain alone changes (a
    /// paused player redraws off this push, so a stale gain would sit on
    /// screen until the next frame).
    @Test func differenceReachesTheRenderWithItsGain() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.differenceGain = .x4
            controller.compareMode = .difference

            let tap = controller.playbackTap
            var tapMode = CompareCompositor.Mode.off
            tap.queue.sync { tapMode = tap.compare }
            guard case .difference(let gain) = tapMode else {
                Issue.record("the tap got \(tapMode), not difference")
                return
            }
            #expect(gain == 4)

            controller.differenceGain = .x16
            tap.queue.sync { tapMode = tap.compare }
            guard case .difference(let bumped) = tapMode else {
                Issue.record("the gain change lost the mode: \(tapMode)")
                return
            }
            #expect(bumped == 16)
        }
    }

    /// The compare mode and the difference gain come back after a relaunch —
    /// a unit that frames against a reference all day wants its difference at
    /// ×16 back, not a hunt through the compare bar every morning. The
    /// defaults are stored as nil, like every other settings field.
    @Test func theCompareModeAndGainSurviveARelaunch() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.compareMode = .difference
            controller.differenceGain = .x16

            let second = CaptureController(
                backends: [("mock", SyntheticSignalBackend())],
                defaults: controller.defaults)
            second.monitorOn = false
            second.audioMonitor.stop()
            second.stopCapture()
            second.folderWatcher?.cancel()
            second.folderWatcher = nil
            defer {
                second.volumePersistTask?.cancel()
                second.lutPersistTask?.cancel()
                second.assistPersistTask?.cancel()
                second.stopCapture()
                second.monitorOn = false
                second.audioMonitor.stop()
            }

            #expect(second.compareMode == .difference)
            #expect(second.differenceGain == .x16)

            // back at the defaults nothing is stored — off is nil, not "off"
            controller.compareMode = .off
            controller.differenceGain = .x1
            let reloaded = CaptureSettings.loaded(from: controller.defaults)
            #expect(reloaded.compareMode == nil)
            #expect(reloaded.compareDifferenceGain == nil)
        }
    }
}
