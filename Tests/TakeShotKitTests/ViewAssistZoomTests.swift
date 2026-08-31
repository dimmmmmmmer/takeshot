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

    /// A wheel tick or a pinch zooms about the POINTER (owner item 4): the
    /// image point under the anchor stays under it, and the whole thing runs
    /// through the draft path — per-event publishes are the lag this
    /// mechanism exists to prevent.
    @Test func anchoredZoomKeepsThePointerPointStill() async throws {
        try await ViewProbe.run { probe in
            let controller = probe.controller
            let viewport = CGSize(width: 1200, height: 700)
            controller.punchInLevel = 2
            controller.commitAssistDraft()

            let anchor = CGPoint(x: 900, y: 250)
            let source = controller.displaySourceSize()
            let before = try #require(controller.liveAssist.placement(
                sourceSize: source, in: viewport))
            let u = (anchor.x - before.rect.minX) / before.rect.width
            let v = (anchor.y - before.rect.minY) / before.rect.height

            controller.magnifyPunchIn(by: 1.5, at: anchor, viewport: viewport)
            controller.assistPersistTask?.cancel() // mid-gesture

            #expect(abs(controller.liveAssist.punchIn - 3) < 0.000_001)
            let after = try #require(controller.liveAssist.placement(
                sourceSize: source, in: viewport))
            #expect(abs(after.rect.minX + u * after.rect.width - anchor.x)
                    < 0.001, "the anchored point slid horizontally")
            #expect(abs(after.rect.minY + v * after.rect.height - anchor.y)
                    < 0.001, "the anchored point slid vertically")
            // still a draft: nothing published per wheel tick
            #expect(controller.assist.punchIn == 2)
        }
    }

    /// The ⌘-scroll step math: symmetric (+N points exactly undoes −N), a
    /// wheel notch is worth more than a point of trackpad swipe, and an
    /// OS-accelerated notch cannot jump more than 2x in one event.
    @Test func theWheelZoomStepIsSymmetricAndCapped() {
        let up = PunchEventView.wheelZoomFactor(deltaY: 3, precise: false)
        let down = PunchEventView.wheelZoomFactor(deltaY: -3, precise: false)
        #expect(up > 1 && down < 1)
        #expect(abs(up * down - 1) < 0.000_001, "zoom in ≠ zoom back out")
        #expect(PunchEventView.wheelZoomFactor(deltaY: 1, precise: false)
                > PunchEventView.wheelZoomFactor(deltaY: 1, precise: true))
        #expect(PunchEventView.wheelZoomFactor(deltaY: 500, precise: true) == 2)
        #expect(PunchEventView.wheelZoomFactor(deltaY: -500, precise: true) == 0.5)
    }

    /// The ceiling is 10x (owner item 42), and everything that depends on the
    /// magnification still behaves there: the pan limit, the anchored zoom and
    /// the readout the popover prints.
    @Test func theZoomReachesTenTimesWithEverythingStillBehaving() async throws {
        #expect(ViewAssist.maxPunchIn == 10)

        try await ViewProbe.run { probe in
            let controller = probe.controller
            let viewport = CGSize(width: 1200, height: 700)

            // the slider can be dragged there, and cannot be pushed past it
            controller.punchInLevel = 10
            #expect(controller.punchInLevel == 10)
            controller.punchInLevel = 40
            #expect(controller.punchInLevel == 10, "the ceiling is not a ceiling")
            controller.commitAssistDraft()

            // only a tenth of the frame is visible, so its centre may travel
            // (1 − 1/10)/2 of a frame — the clamp scales with the level rather
            // than staying at whatever 8x needed
            #expect(abs(controller.liveAssist.panLimit - 0.45) < 0.000_001)
            for _ in 0..<40 {
                controller.panPunchIn(by: CGSize(width: -400, height: -400),
                                      viewport: viewport)
            }
            #expect(controller.liveAssist.panX == 0.45)
            #expect(controller.liveAssist.panY == 0.45)
            // …and the picture is still on screen: the visible window sits
            // inside the frame at the limit, not past its edge
            let placed = try #require(controller.liveAssist.placement(
                sourceSize: controller.displaySourceSize(), in: viewport))
            #expect(placed.rect.maxX >= viewport.width - 0.001,
                    "panned to the limit at 10x, the picture left the viewport")
            #expect(placed.rect.minX <= 0.001)

            // the cursor-anchored maths holds at the ceiling: a zoom that
            // cannot grow any further must not slide the picture under the
            // pointer either
            let anchor = CGPoint(x: 950, y: 200)
            let source = controller.displaySourceSize()
            let before = try #require(controller.liveAssist.placement(
                sourceSize: source, in: viewport))
            let u = (anchor.x - before.rect.minX) / before.rect.width
            controller.magnifyPunchIn(by: 2, at: anchor, viewport: viewport)
            controller.assistPersistTask?.cancel()
            #expect(controller.liveAssist.punchIn == 10)
            let after = try #require(controller.liveAssist.placement(
                sourceSize: source, in: viewport))
            #expect(abs(after.rect.minX + u * after.rect.width - anchor.x) < 0.001,
                    "the anchored point slid at the ceiling")

            // and zooming back out brings the picture with it
            controller.punchInLevel = 1
            #expect(controller.liveAssist.panX == 0)
            #expect(controller.liveAssist.panY == 0)
        }
    }

    /// The popover has to be able to PRINT 10x. The readout is a fixed-width
    /// column beside the slider, and "10.0x" is a character wider than every
    /// magnification the old ceiling could reach.
    @Test func theZoomReadoutFitsAtTheCeiling() async throws {
        try await ViewProbe.run { probe in
            probe.controller.punchInLevel = 1
            probe.controller.commitAssistDraft()
            let single = probe.fittingSizes { AssistControlsPanel() }

            probe.controller.punchInLevel = ViewAssist.maxPunchIn
            probe.controller.commitAssistDraft()
            let double = probe.fittingSizes { AssistControlsPanel() }

            #expect(double.en.width == single.en.width,
                    "the panel reflowed at 10x: \(single.en) → \(double.en)")
            #expect(double.ru.width == single.ru.width)

            let box = AssistControlsPanel.contentWidth
            let minimum = probe.minimumWidths { AssistControlsPanel() }
            #expect(minimum.ru <= box,
                    "at 10x the Russian panel wants \(minimum.ru)pt of \(box)")
            #expect(minimum.en <= box)
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
                // The tree has to be BUILT, not measured: the input registers
                // itself in `makeNSView`.
                ViewRender.mountTree(probe.hosted(player),
                                     in: CGSize(width: 1280, height: 720))
                #expect(PunchEventView.mountCount > before,
                        "this fullscreen player has no pan/zoom input")
            }
        }
    }
}
