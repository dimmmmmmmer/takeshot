import AppKit
import CaptureCore
import Combine
import SwiftUI
import Testing

@testable import TakeShotKit

/// **The blend row shows the value the picture is using.**
///
/// `blendOpacity` moved off `CaptureController` so a drag would stop waking 114
/// `@EnvironmentObject` sites per tick — that is what fixed the lag the owner
/// reported on the wipe and the blend. What it left behind was this row: the
/// controller's property became a plain forwarder, so binding to it published
/// nothing and the "%" beside the slider showed whatever number happened to be
/// there at the last unrelated publish. An operator dialling an exact opacity
/// was reading a figure that disagreed with what they were looking at.
///
/// **What is pinned here is the invariant that makes the fix necessary, not the
/// fix.** A render cannot tell an observing row from a non-observing one: an
/// offscreen `NSHostingView` re-evaluates the tree on every `cacheDisplay`, so
/// dropping `@ObservedObject` from the row and re-rendering produces identical
/// bytes — planted and seen passing. What a test CAN hold is why the row has to
/// observe `CompareLive` at all: because the controller deliberately does not
/// publish this value, and a view bound through it would therefore never be
/// invalidated.
@MainActor
struct ViewCompareBlendTests {
    /// A recorder for one object's publishes.
    private final class Publishes {
        private(set) var count = 0
        private var token: AnyCancellable?

        init<T: ObservableObject>(of object: T)
            where T.ObjectWillChangePublisher == ObservableObjectPublisher {
            token = object.objectWillChange.sink { [self] _ in count += 1 }
        }
    }

    /// The drag publishes on `CompareLive` and NOT on the controller. That is
    /// the whole performance argument — and it is exactly why the row cannot be
    /// bound through the controller.
    @Test func theBlendPublishesOnCompareLiveAndNotOnTheController() async throws {
        try await ControllerHarness.run { controller, _ in
            let live = Publishes(of: controller.compareLive)
            let wide = Publishes(of: controller)

            controller.blendOpacity = 0.9

            #expect(live.count >= 1, """
                nothing published the new opacity — a row observing \
                `CompareLive` would never be told
                """)
            #expect(wide.count == 0, """
                a compare drag woke every `@EnvironmentObject` site again, \
                which is the lag this value was moved to fix
                """)
        }
    }

    /// The same for the wipe, which is the other half of the same move and the
    /// one the owner reported first ("вот кстати то что шторка лагает").
    @Test func theWipePublishesTheSameWay() async throws {
        try await ControllerHarness.run { controller, _ in
            let live = Publishes(of: controller.compareLive)
            let wide = Publishes(of: controller)

            controller.wipePosition = 0.75

            #expect(live.count >= 1)
            #expect(wide.count == 0,
                    "a wipe drag woke the controller")
        }
    }

    /// And the row draws the value rather than a constant: two opacities, two
    /// pictures. This does not prove observation — see the note above — it
    /// proves the readout is wired to the number at all.
    @Test func theRowDrawsTheValueRatherThanAConstant() async throws {
        try await ControllerHarness.run { controller, root in
            try RemoteHarness.seedTake(controller, in: root, named: "A001C01",
                                       clip: 1)
            controller.viewerMode = .playback
            controller.playbackURL = controller.takes.first?.url
            controller.compareMode = .blend
            let size = CGSize(width: 420, height: 40)

            controller.compareLive.blendOpacity = 0.1
            let low = ViewRender.meanBrightness(
                CompareControls().environmentObject(controller), in: size)
            controller.compareLive.blendOpacity = 0.9
            let high = ViewRender.meanBrightness(
                CompareControls().environmentObject(controller), in: size)

            #expect(low > 0, "the compare row drew nothing at all")
            #expect(low != high,
                    "10 % and 90 % draw the same row — the readout is a constant")
        }
    }

    /// Writing still goes THROUGH the controller: the row observes
    /// `CompareLive`, but the setter is what pushes the value into the pipeline
    /// and persists it on the debounce.
    @Test func theRowStillWritesThroughTheController() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.blendOpacity = 0.42
            #expect(controller.compareLive.blendOpacity == 0.42)
            #expect(controller.blendOpacity == 0.42,
                    "the forwarder and the object disagree")
        }
    }
}
