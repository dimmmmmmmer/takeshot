import AppKit
import CaptureCore
import SwiftUI
import Testing

@testable import TakeShotKit

/// The aids that are DRAGGED: the zebra and peaking sliders, the punch-in level
/// a pinch drives, and the pan.
///
/// All of them go through one mechanism (`applyAssistPreview` in
/// CaptureController+Assist) because they share one problem: `assist` is
/// @Published, and a write per pointer event re-lays out every view observing
/// the controller. That is the lag the LUT intensity slider had, and this suite
/// is what says it has not come back.
@MainActor
struct ViewAssistZoomTests {
    /// A slider tick reaches the preview immediately and the published state not
    /// at all until the gesture settles.
    ///
    /// The pending fold is cancelled before anything is asserted rather than
    /// asserted against a stopwatch: "has not been published yet" would
    /// otherwise be a race a loaded machine wins, and a debounce landing early
    /// is not the failure this is about.
    @Test func draggedAidsReachThePreviewWithoutPublishing() async throws {
        try await ViewProbe.run { probe in
            let controller = probe.controller
            controller.assist.zebraOn = true
            let published = controller.assist.zebraThreshold

            for tick in 1...12 {
                controller.zebraThreshold = 0.70 + Double(tick) * 0.01
            }
            controller.assistPersistTask?.cancel()

            #expect(controller.zebraThreshold == 0.82, "the slider did not take")
            #expect(controller.liveAssist.zebraThreshold == 0.82,
                    "the preview is not showing the value being dragged")
            #expect(controller.assistLive.hasDraft)
            #expect(controller.assist.zebraThreshold == published,
                    "twelve ticks published twelve times — the lag is back")

            controller.commitAssistDraft()
            #expect(controller.assist.zebraThreshold == 0.82)
            #expect(!controller.assistLive.hasDraft)
        }
    }

    /// And the debounce does fold it in on its own — waited out by polling for
    /// the outcome, not by sleeping for the window.
    @Test func theDebounceFoldsInADraggedValueByItself() async throws {
        try await ViewProbe.run { probe in
            let controller = probe.controller
            controller.peakingIntensity = 21
            let folded = await ControllerWait.until {
                controller.assist.peakingIntensity == 21
            }
            #expect(folded, "the debounce never published the value")
            #expect(!controller.assistLive.hasDraft)
        }
    }

    /// Clicking a toggle right after letting go of a slider must not throw the
    /// slider's value away.
    @Test func aClickedAidFoldsInWhateverWasBeingDragged() async throws {
        try await ViewProbe.run { probe in
            let controller = probe.controller
            controller.peakingIntensity = 26
            controller.assistPersistTask?.cancel() // mid-gesture, deterministically
            #expect(controller.assist.peakingIntensity != 26)

            controller.setAssist { $0.peakingOn = true }
            #expect(controller.assist.peakingIntensity == 26,
                    "the click discarded the value the operator just set")
            #expect(controller.assist.peakingOn)
            #expect(!controller.assistLive.hasDraft)
        }
    }

    /// The pinch gesture: relative deltas accumulate, clamped, and the hotkey
    /// toggle sees the level that is on screen rather than the published one.
    @Test func pinchingAccumulatesAndTheHotkeyTogglesOffWhatItSees() async throws {
        try await ViewProbe.run { probe in
            let controller = probe.controller
            for _ in 0..<20 { controller.magnifyPunchIn(by: 1.06) }
            controller.assistPersistTask?.cancel() // still pinching
            #expect(controller.punchInLevel > 2)
            #expect(controller.isPunchedIn)

            // published state is still 1x — nothing has re-rendered the window
            #expect(controller.assist.punchIn == 1)
            controller.togglePunchIn()
            #expect(controller.assist.punchIn == 1,
                    "the hotkey toggled off a magnification it could not see")
            #expect(!controller.isPunchedIn)

            for _ in 0..<200 { controller.magnifyPunchIn(by: 1.5) }
            #expect(controller.punchInLevel == ViewAssist.maxPunchIn)
        }
    }

    /// A drag moves the picture with the pointer: the translation is converted
    /// through the placement the renderer uses, so a 60pt drag on a 1200pt-wide
    /// image is exactly a twentieth of the frame. It used to be divided by an
    /// invented constant instead.
    @Test func draggingPansByThePointerDistance() async throws {
        try await ViewProbe.run { probe in
            let controller = probe.controller
            let viewport = CGSize(width: 1200, height: 700)
            controller.punchInLevel = 2
            controller.commitAssistDraft()

            let placed = try #require(controller.liveAssist.placement(
                sourceSize: controller.displaySourceSize(), in: viewport))
            controller.panPunchIn(by: CGSize(width: 60, height: 0),
                                  viewport: viewport)
            #expect(abs(controller.liveAssist.panX + 60 / Double(placed.rect.width))
                    < 0.000_001,
                    "60pt of drag came out as \(controller.liveAssist.panX)")

            // and it stops at the frame edge instead of pulling in letterbox
            for _ in 0..<40 {
                controller.panPunchIn(by: CGSize(width: -200, height: -200),
                                      viewport: viewport)
            }
            let limit = controller.liveAssist.panLimit
            #expect(controller.liveAssist.panX == limit)
            #expect(controller.liveAssist.panY == limit)

            // unmagnified there is nothing to pan
            controller.setAssist { $0.setPunchIn(1) }
            controller.panPunchIn(by: CGSize(width: 100, height: 100),
                                  viewport: viewport)
            #expect(controller.liveAssist.panX == 0)
        }
    }

    /// Drag-to-pan did not work in the fullscreen player at all: the gesture was
    /// attached to the windowed viewer surface, and the fullscreen windows host
    /// mounts of their own. It lives on `playerTopBadges` now — the one mount all
    /// three share — so rendering either fullscreen player has to bring the zoom
    /// input with it.
    @Test func bothFullscreenPlayersCarryTheZoomInput() async throws {
        try await ViewProbe.run { probe in
            for player in [AnyView(LiveFullscreenView()),
                           AnyView(PlaybackFullscreenView())] {
                let before = PunchEventView.mountCount
                _ = ViewRender.laidOutSize(probe.hosted(player),
                                           in: CGSize(width: 1280, height: 720))
                #expect(PunchEventView.mountCount > before,
                        "this fullscreen player has no pan/zoom input")
            }
        }
    }
}
