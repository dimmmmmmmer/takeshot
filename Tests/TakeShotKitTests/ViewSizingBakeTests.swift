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
