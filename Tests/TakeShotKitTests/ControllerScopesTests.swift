import AppKit
import CaptureCore
import Combine
import Foundation
import Testing

@testable import TakeShotKit

/// The scopes' side of the controller: what region they analyze, where the
/// separate window goes, and the one-overlay-at-a-time rule the panels over the
/// player share.
@MainActor
struct ControllerScopesTests {
    // MARK: - what the scopes analyze (punch-in)

    /// Punched in, the scopes must read the crop on screen. The derivation is
    /// checked here at the controller level; that the ANALYZER then samples that
    /// crop is `ScopeRegionTests` in CaptureCoreTests.
    @Test func theScopeRegionFollowsThePunchIn() async throws {
        try await ControllerHarness.run { controller, _ in
            #expect(controller.scopeRegion == .full)

            controller.togglePunchIn()
            #expect(controller.assist.punchIn == 2)
            let punched = controller.scopeRegion
            #expect(punched.width == 0.5)
            #expect(punched.x == 0.25)
            #expect(punched.y == 0.25)

            controller.assist.panX = 0.25
            #expect(controller.scopeRegion.x == 0.5)
            #expect(controller.scopeRegion.y == 0.25)

            controller.togglePunchIn() // back out — and the pan resets with it
            #expect(controller.scopeRegion == .full)
        }
    }

    /// …and it reaches the analyzer, not just the controller's own derivation.
    ///
    /// The playback tap is the one of the three sources a test can hold: the live
    /// pipeline's end of the wire is `PipelineScopeTests` in CaptureCoreTests,
    /// and `RawPlayerModel` cannot be constructed without the Blackmagic RAW
    /// SDK, so its wiring is covered by `RawPlayback+Scopes` review only.
    @Test func thePunchInReachesThePlaybackAnalyzer() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.togglePunchIn()
            controller.assist.panX = 0.25
            controller.playbackTap.queue.sync {} // the setter is queue-async
            #expect(controller.playbackTap.scopeRegion == controller.scopeRegion)
            #expect(controller.playbackTap.scopeRegion != .full)

            controller.togglePunchIn()
            controller.playbackTap.queue.sync {}
            #expect(controller.playbackTap.scopeRegion == .full)
        }
    }

    /// A display assist that has nothing to do with framing must not move the
    /// analyzed region (the assist observer pushes it on every change).
    @Test func otherAssistsLeaveTheRegionAlone() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.assist.zebraOn = true
            controller.assist.desqueeze = 2
            #expect(controller.scopeRegion == .full)
        }
    }

    // MARK: - scopes window placement

    @Test func theScopesWindowFrameSurvivesARelaunch() async throws {
        try await ControllerHarness.run { controller, _ in
            let screen = NSRect(x: 0, y: 0, width: 2560, height: 1440)
            #expect(controller.savedScopesWindowFrame(screens: [screen]) == nil,
                    "nothing has been saved yet")

            let frame = NSRect(x: 300, y: 220, width: 980, height: 380)
            controller.saveScopesWindowFrame(frame)
            #expect(controller.savedScopesWindowFrame(screens: [screen]) == frame)

            // a fresh controller on the same preferences is what a relaunch is
            let relaunched = CaptureController(
                backends: [], defaults: controller.defaults,
                audioInputs: FakeAudioInputProvider())
            #expect(relaunched.savedScopesWindowFrame(screens: [screen]) == frame)
        }
    }

    /// The cart had two displays; the laptop has one. A frame that lands where
    /// there is no screen any more must be ignored, not restored off-screen.
    @Test func aFrameOnAMissingDisplayIsIgnored() {
        let laptop = NSRect(x: 0, y: 0, width: 1512, height: 900)
        let onLaptop = NSRect(x: 100, y: 100, width: 980, height: 380)
        #expect(CaptureController.usableScopesFrame(onLaptop,
                                                    screens: [laptop]) == onLaptop)

        let onTheMissingSecondDisplay = NSRect(x: 3000, y: 1200,
                                               width: 980, height: 380)
        #expect(CaptureController.usableScopesFrame(onTheMissingSecondDisplay,
                                                    screens: [laptop]) == nil)
        // a sliver on screen is not "reachable" either
        let mostlyOff = NSRect(x: 1450, y: 100, width: 980, height: 380)
        #expect(CaptureController.usableScopesFrame(mostlyOff,
                                                    screens: [laptop]) == nil)
        // nor is a frame too small to hold the panel's own minimum
        let squashed = NSRect(x: 100, y: 100, width: 200, height: 120)
        #expect(CaptureController.usableScopesFrame(squashed,
                                                    screens: [laptop]) == nil)
    }

    // MARK: - one overlay at a time (item 27's mechanism)

    @Test func openingOnePlayerOverlayClosesTheOther() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.showAudioPanel = true
            controller.showScopesOverlay = true
            #expect(!controller.showAudioPanel,
                    "the audio panel should have closed when the scopes opened")
            #expect(controller.showScopes)

            controller.showAudioPanel = true
            #expect(!controller.showScopesOverlay)
            #expect(!controller.showScopes, "scope analysis must stop with it")
        }
    }

    /// What Esc and a click on the picture call.
    @Test func dismissingPlayerOverlaysClosesWhateverIsOpen() async throws {
        try await ControllerHarness.run { controller, _ in
            #expect(!controller.anyPlayerOverlayOpen)

            controller.showScopesOverlay = true
            #expect(controller.anyPlayerOverlayOpen)
            controller.dismissPlayerOverlays()
            #expect(!controller.showScopesOverlay)
            #expect(!controller.anyPlayerOverlayOpen)

            controller.showAudioPanel = true
            controller.dismissPlayerOverlays()
            #expect(!controller.showAudioPanel)
        }
    }

    /// The separate window is not one of the player overlays: it does not cover
    /// the picture, so opening the audio panel must not close it.
    /// The switch the badge, the ⌃W key and the View menu all press is the
    /// write side of the reading they all light from.
    ///
    /// They lit from `showScopes` (overlay OR window) and wrote
    /// `showScopesOverlay` alone, and the overlay is deliberately not drawn
    /// while the scopes window is up. So with the scopes in their own window the
    /// badge read ON and pressing it changed nothing visible — while latching
    /// the overlay flag, which then put a panel over the picture the moment that
    /// window was closed. Nothing in the suite could see it: the flag is what
    /// every existing scopes test asserts on, and it was being set.
    @Test func theScopesSwitchReachesEverythingItsLightCovers() async throws {
        try await ControllerHarness.run { controller, _ in
            #expect(!controller.showScopes, "the fixture starts with scopes up")
            #expect(!controller.showScopesOverlay)

            controller.toggleScopes()
            #expect(controller.showScopesOverlay)
            #expect(controller.showScopes)

            controller.toggleScopes()
            #expect(!controller.showScopesOverlay)
            #expect(!controller.showScopes)

            // the scopes are up because the WINDOW is up: the switch reads ON,
            // and pressing it must not quietly arm the overlay behind it
            controller.scopesWindowOpen = true
            #expect(controller.showScopes)
            controller.toggleScopes()
            #expect(!controller.showScopesOverlay,
                    "pressing the lit switch latched an overlay nobody can see")

            // …and with the window gone, the switch still turns them on
            controller.scopesWindowOpen = false
            #expect(!controller.showScopes)
            controller.toggleScopes()
            #expect(controller.showScopes)
            controller.showScopesOverlay = false
        }
    }

    @Test func theScopesWindowIsNotClosedByThePlayerOverlays() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.scopesWindowOpen = true
            controller.showAudioPanel = true
            #expect(controller.scopesWindowOpen)
            #expect(controller.showScopes)
        }
    }

    // MARK: - what republishes the scopes (owner item 34)

    /// A timecode or a meter tick must not republish the scopes.
    ///
    /// The scope panel is the most expensive body in the app to re-run — four
    /// trace views, their graticules and a density image each — and it used to
    /// observe `LiveSignal`, where the timecode arrives every frame and the
    /// meters arrive with every packet that differs from the last. That is two
    /// to eight full rebuilds per analysis it actually had to draw, and during
    /// a reorder drag every one of them relaid out the grid the operator was
    /// moving a box around in.
    @Test func aTimecodeOrMeterTickDoesNotRepublishTheScopes() async throws {
        try await ControllerHarness.run { controller, _ in
            var scopePublishes = 0
            let token = controller.scopes.objectWillChange.sink { _ in
                scopePublishes += 1
            }
            defer { token.cancel() }

            var timecode = Timecode(hours: 10, minutes: 0, seconds: 0,
                                    frames: 0, fps: 25)
            for tick in 0..<100 {
                timecode = timecode.advanced(by: 1)
                controller.live.currentTimecode = timecode
                controller.live.audioLevels = [Float(tick) * -0.5]
            }
            #expect(scopePublishes == 0,
                    "the live signal republished the scopes \(scopePublishes) times")

            controller.scopes.data = nil
            #expect(scopePublishes == 1, "an analysis has to reach the panel")
        }
    }
}
