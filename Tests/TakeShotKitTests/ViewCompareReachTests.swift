import AppKit
import CaptureCore
import SwiftUI
import Testing

@testable import TakeShotKit

/// Whether the operator can GET to the pinned-reference compare, as opposed to
/// whether it fits.
///
/// Its own suite rather than three more tests in `ViewPlayerBadgeTests`, and for
/// the reason the LTC menu tests were split out of that file: it is a different
/// question. That suite is a family of WIDTHS — does the bar fit the picture,
/// does Russian cost more than the slot has — and every one of its compare
/// checks sets `referencePinned = true` before it measures, because a bar with
/// nothing pinned is not the bar whose width is interesting. That is exactly the
/// state in which the bug lived: the row was mounted only once something was
/// pinned, and `ComparePinControls` — the app's only caller of
/// `pinReferenceFromCurrentFrame()`, with no menu item, no hotkey and no remote
/// command — was inside it. A suite that always arrives already pinned can never
/// ask how the operator got there.
@Suite @MainActor struct ViewCompareReachTests {
    /// There is a way INTO the pinned-reference compare from a fresh install.
    ///
    /// This is the test the compare suite did not have, and the bug it did not
    /// catch. `ComparePinControls` is the only caller of
    /// `pinReferenceFromCurrentFrame()` anywhere in the app — no menu item, no
    /// hotkey, no remote command — and it lives in the compare bar, which in
    /// record mode was mounted only once `referencePinned` was already true. So
    /// live compare could not be entered at all: the key was inside the lock,
    /// exactly as it was for the taught REC indicator.
    ///
    /// Every check around this one is a WIDTH, and each of them sets
    /// `referencePinned = true` before it measures — which is the state that
    /// hides the bug. So this one starts where a fresh install starts: a signal
    /// and nothing else.
    @Test func theReferencePinIsReachableFromAFreshInstall() async throws {
        try await ViewProbe.run { probe in
            let controller: CaptureController = probe.controller
            #expect(!controller.referencePinned,
                    "the fixture starts pinned — this test proves nothing")
            #expect(controller.playbackURL == nil)
            #expect(controller.viewerMode == CaptureController.ViewerMode.record)

            // no source running: nothing to pin, so nothing is offered
            controller.isCapturing = false
            #expect(!controller.showsCompareBar,
                    "the compare row is offered over a player with no frame in it")

            // a live signal and nothing else — where a fresh install stands
            controller.isCapturing = true
            #expect(controller.showsCompareBar,
                    "live compare has no way in: the row holding the only pin control is not mounted")
            #expect(!controller.compareHasBSide)

            // …and what is offered is the door, not a bar of controls that
            // cannot act because there is nothing to compare against
            let bar: CGSize = probe.fittingSize(CompareControls())
            let door: CGSize = probe.fittingSize(ComparePinControls())
            #expect(door.width > 0, "the pin control renders as nothing")
            #expect(bar.width <= door.width + 2 * CompareControls.platePadding + 1,
                    "the unpinned record bar is \(bar.width)pt around a \(door.width)pt door")

            // pressing it pins, and the rest of the bar follows it open
            controller.pinReferenceFromCurrentFrame()
            #expect(controller.referencePinned,
                    "the pin control did not pin a reference")
            #expect(controller.compareHasBSide)
            let opened: CGSize = probe.fittingSize(CompareControls())
            #expect(opened.width > bar.width,
                    "pinning opened nothing: \(bar.width)pt → \(opened.width)pt")
        }
    }

    /// The door is in the bar in EVERY state the bar is shown in.
    ///
    /// The collapse above is a way in only while it cannot be collapsed away:
    /// a later edit that hides the pin behind an engaged mode, or behind a
    /// clip, puts the lock back. Measured as "the bar is never narrower than
    /// its door", which is a size and says the same thing in both languages.
    @Test func everyCompareBarCarriesThePin() async throws {
        try await ViewProbe.run { probe in
            let controller: CaptureController = probe.controller
            try ViewFixtures.seedTakes(controller, in: probe.root)
            let door: CGSize = probe.fittingSize(ComparePinControls())

            for viewer in [CaptureController.ViewerMode.record, .playback] {
                controller.viewerMode = viewer
                controller.isCapturing = viewer == .record
                controller.playbackURL = viewer == .playback
                    ? probe.root.appendingPathComponent("a.mov") : nil
                for pinned in [false, true] {
                    controller.referencePinned = pinned
                    for mode in [CaptureController.CompareMode.off, .wipe,
                                 .blend, .difference, .sideBySide] {
                        controller.compareMode = mode
                        #expect(controller.showsCompareBar,
                                "\(viewer)/\(mode)/pinned=\(pinned): no compare row at all")
                        let bar: CGSize = probe.fittingSize(CompareControls())
                        #expect(bar.width >= door.width,
                                "\(viewer)/\(mode) pinned=\(pinned): bar \(bar.width)pt, pin \(door.width)pt")
                    }
                }
            }
        }
    }

    /// One decision about whether the row is on screen, and one about whether
    /// it has a B side — the wipe seam's handle reads the second of them, so
    /// the bar and the seam cannot come to disagree about what a B side is.
    /// (The sync-play half of the same decision is in `ControllerSyncPlayTests`,
    /// where the grid can be opened for real.)
    @Test func theCompareRowIsOneDecision() async throws {
        try await ViewProbe.run { probe in
            let controller: CaptureController = probe.controller
            controller.viewerMode = .playback
            #expect(!controller.showsCompareBar, "no clip loaded, no compare row")
            #expect(!controller.compareHasBSide)

            controller.playbackURL = probe.root.appendingPathComponent("a.mov")
            #expect(controller.showsCompareBar)
            #expect(controller.compareHasBSide)

            for mode in [CaptureController.CompareMode.off, .wipe, .blend,
                         .difference, .sideBySide] {
                controller.compareMode = mode
                #expect(controller.showsWipeHandle
                        == (mode == .wipe && controller.compareHasBSide),
                        "\(mode): the seam and the bar disagree about the B side")
            }
        }
    }
}
