import CaptureCore
import Testing

@testable import TakeShotKit

/// **The two keys the assist popover needed** (owner: "нам нужен хоткей типа
/// сбросить все по опер помощи и включить/отключить ее видимость").
///
/// One takes the aids off the picture without forgetting them; the other puts
/// everything back to how the app ships. What each of them does NOT touch is
/// the half of this worth testing.
@Suite @MainActor struct ControllerAssistKeysTests {
    private func loud() -> ViewAssist {
        var assist = ViewAssist()
        assist.colorTool = .falseColor
        assist.zebraOn = true
        assist.peakingOn = true
        assist.guides.ratio = 2.39
        assist.guides.safeAreas = true
        assist.desqueeze = 2
        assist.setPunchIn(3)
        assist.chroma.isOn = true
        assist.chroma.tolerance = 0.42
        return assist
    }

    /// **The bypass keeps the set-up and the framing.** The tools and the
    /// guides come off the picture; the desqueeze and the punch-in are how the
    /// operator is framing the shot and stay exactly where they are.
    @Test func hidingTheAidsKeepsEverythingItIsNotDrawing() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.assist = loud()
            controller.toggleAssistsHidden()
            #expect(controller.assistsHidden)
            // the STORED value is untouched — that is the whole point
            #expect(controller.assist.colorTool == .falseColor)
            #expect(controller.assist.chroma.tolerance == 0.42)

            let shown = controller.assist.withoutAids
            #expect(shown.colorTool == .off)
            #expect(!shown.zebraOn && !shown.peakingOn)
            #expect(shown.guides.isEmpty)
            #expect(!shown.chroma.isOn)
            #expect(shown.desqueeze == 2, """
                the bypass unsqueezed the picture — that is framing, not an aid
                """)
            #expect(shown.punchIn == 3, "the bypass zoomed the picture out")

            controller.toggleAssistsHidden()
            #expect(!controller.assistsHidden)
            #expect(controller.assist.colorTool == .falseColor,
                    "the aids did not come back")
        }
    }

    /// **The reset zeroes the popover and keeps the green screen's dial-in.**
    /// A colour picked off the set and a tolerance found over ten minutes is
    /// set-up; the switch beside it is what "reset" is about.
    @Test func resettingZeroesTheAidsAndKeepsTheKeysDialIn() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.assist = loud()
            controller.assistsHidden = true
            controller.resetAssists()

            #expect(controller.assist.colorTool == .off)
            #expect(!controller.assist.zebraOn && !controller.assist.peakingOn)
            #expect(controller.assist.guides.isEmpty)
            #expect(controller.assist.desqueeze == 1)
            #expect(controller.assist.punchIn == 1)
            #expect(!controller.assist.isShowingAid, """
                the badge would still be lit after a reset
                """)
            #expect(controller.assist.chroma.tolerance == 0.42, """
                the reset threw away the key's dial-in
                """)
            #expect(!controller.assist.chroma.isOn)
            #expect(!controller.assistsHidden, """
                a reset that leaves the bypass on is a state where nothing is \
                set and nothing shows
                """)
        }
    }
}
