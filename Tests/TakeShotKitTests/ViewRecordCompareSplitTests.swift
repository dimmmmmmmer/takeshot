import CaptureCore
import Foundation
import SwiftUI
import Testing

@testable import TakeShotKit

/// **A/B works in record mode, against the pinned reference.**
///
/// The compare picker has always offered five modes in both viewer modes, and
/// in record the fifth did nothing at all: `showsCompareSplit` asked for
/// playback, so the render never drew a split and the operator got the live
/// picture with a mode selected over it (owner: "а/б режим при пине рефа на
/// странице река не работает").
///
/// The other three modes composite the reference INTO the live frame, so they
/// needed no second surface. A split is two pictures, and the reference had no
/// way onto the screen except through the compositor.
@Suite @MainActor struct ViewRecordCompareSplitTests {
    /// The rule itself, in every state that decides it.
    @Test func theSplitIsOfferedWhereverThereIsSomethingToCompareAgainst()
        async throws {
        try await ControllerHarness.run { controller, root in
            controller.viewerMode = .record
            controller.compareMode = .sideBySide
            #expect(!controller.showsCompareSplit,
                    "a split of the live picture against nothing")

            controller.referencePinned = true
            #expect(controller.showsCompareSplit,
                    "A/B in record still draws one picture")

            // the other three composite into the one surface and must NOT
            // split — a split of an already-composited picture shows the
            // compare twice
            for mode in [CaptureController.CompareMode.wipe, .blend,
                         .difference, .off] {
                controller.compareMode = mode
                #expect(!controller.showsCompareSplit,
                        "\(mode) drew a split")
            }
            controller.compareMode = .sideBySide

            // playback is unchanged: the clip in the player is the B side
            controller.referencePinned = false
            controller.viewerMode = .playback
            #expect(!controller.showsCompareSplit)
            let clip = root.appendingPathComponent("A001C001.mov")
            try Data([0x00]).write(to: clip)
            controller.playbackURL = clip
            #expect(controller.showsCompareSplit)
        }
    }

    /// **And the reference really reaches a surface of its own.**
    ///
    /// The rule above can be satisfied by a split that draws two live panes,
    /// or a black one. What says otherwise is the pipeline's own registry: a
    /// mounted `PreviewMount.reference` registers a layer with it, so counting
    /// them is how a headless render can see which picture the B pane is
    /// showing. The same trick `PunchEventView.mountCount` exists for.
    @Test func theRecordSplitMountsTheReferenceOnItsOwnSurface() async throws {
        try await ViewProbe.run { probe in
            let controller = probe.controller
            controller.viewerMode = .record
            controller.compareMode = .sideBySide
            controller.referencePinned = true
            try #require(controller.pipeline.referenceSinks.all().isEmpty,
                         "something had already mounted a reference surface")

            try await probe.mounted(ComparePlaybackSplit(),
                                    in: CGSize(width: 800, height: 450)) {
                #expect(controller.pipeline.referenceSinks.all().count == 1, """
                    the record split mounted \
                    \(controller.pipeline.referenceSinks.all().count) reference \
                    surfaces — the B pane is not showing the pinned frame
                    """)
            }
        }
    }

    /// …and in PLAYBACK the same view mounts none of them: the B pane there is
    /// the take in the player, and a reference surface would be a third
    /// picture nobody asked for.
    @Test func thePlaybackSplitMountsNoReferenceSurface() async throws {
        try await ViewProbe.run { probe in
            let controller = probe.controller
            let clip = probe.root.appendingPathComponent("A001C001.mov")
            try Data([0x00]).write(to: clip)
            controller.viewerMode = .playback
            controller.playbackURL = clip
            controller.compareMode = .sideBySide

            try await probe.mounted(ComparePlaybackSplit(),
                                    in: CGSize(width: 800, height: 450)) {
                #expect(controller.pipeline.referenceSinks.all().isEmpty,
                        "the playback split mounted a reference surface")
            }
        }
    }
}
