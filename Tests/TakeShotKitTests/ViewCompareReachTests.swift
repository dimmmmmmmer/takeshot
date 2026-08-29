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
    /// There is a way INTO the pinned-reference compare from a fresh install —
    /// and the door is in PLAYBACK.
    ///
    /// This is the test the compare suite did not have, and the bug it did not
    /// catch: `ComparePinControls` is the only caller of
    /// `pinReferenceFromCurrentFrame()` anywhere in the app — no menu item, no
    /// hotkey, no remote command — so if the row holding it is not mounted,
    /// live compare cannot be entered at all. The key was inside the lock,
    /// exactly as it was for the taught REC indicator.
    ///
    /// **The door has since MOVED, on the owner's call**, and what this test
    /// keeps is the property rather than the place: it used to stand in record
    /// mode, over a live signal and nothing else, which meant the button was on
    /// screen for the whole shooting day (owner: "даже в режиме record у меня
    /// всегда висит кнопка пина. она должна быть видна тогда когда я включил
    /// какой либо записанный шот/other content в просмотре"). It is now offered
    /// while a clip is under review, which is also the case the METHOD is built
    /// around — from playback it takes the frame on screen, hands it to the
    /// pipeline and switches the viewer back to record, so the live picture is
    /// then being compared against a frame of a take.
    ///
    /// What that cost is worth writing down: pinning the LIVE frame — freeze
    /// the current framing, then watch the live picture against it — has no
    /// entry point any more. Putting it back is one condition.
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

            // a live signal and nothing else: the row is there for the mode
            // picker, and the pin is NOT — there is no take to pin a frame of
            controller.isCapturing = true
            #expect(controller.showsCompareBar)
            #expect(!controller.compareHasBSide)
            #expect(probe.fittingSize(ComparePinControls()).width == 0,
                    "the pin is offered over a live signal with no clip in review")

            // …and a clip under review is the door. A REAL clip, played for
            // real: the pin takes the frame the tap is holding, so a fixture
            // that only sets `playbackURL` would prove the button is drawn and
            // nothing about whether pressing it does anything.
            let media = try MediaFixtures.makeDirectory("compare-reach")
            defer { try? FileManager.default.removeItem(at: media) }
            let clip = try await MediaFixtures.writeClip(
                at: media.appendingPathComponent("reviewed.mov"), frames: 12)
            MediaFixtures.silence(controller)
            defer { MediaFixtures.stopPlayback(controller) }
            controller.play(url: clip)
            #expect(await ControllerWait.until {
                controller.playbackTap.currentBuffer() != nil
            }, "the review clip never produced a frame")
            #expect(controller.isReviewingSingleClip,
                    "the fixture did not reach the state the door is offered in")
            let door: CGSize = probe.fittingSize(ComparePinControls())
            #expect(door.width > 0,
                    "a clip is under review and the pin control renders as nothing")

            // pressing it pins, and lands the operator in the mode that shows
            // the live picture against what was just pinned
            controller.pinReferenceFromCurrentFrame()
            #expect(controller.lastError == nil,
                    "the pin refused: \(controller.lastError ?? "")")
            #expect(controller.referencePinned,
                    "the pin control did not pin a reference")
            #expect(controller.viewerMode == CaptureController.ViewerMode.record,
                    "pinning from a clip left the viewer in playback")
            #expect(controller.compareHasBSide)
        }
    }

    /// The door is in the bar in every state it is OFFERED in.
    ///
    /// The collapse is a way in only while it cannot be collapsed away: a later
    /// edit that hides the pin behind an engaged mode, or behind a pinned
    /// reference, puts the lock back. Measured as "the bar is never narrower
    /// than its door", which is a size and says the same thing in both
    /// languages.
    ///
    /// Record mode is asserted from the other side now — the pin is offered
    /// NOWHERE in it — so this walk pins down both halves of the rule rather
    /// than only the half that used to hold everywhere.
    @Test func everyCompareBarCarriesThePin() async throws {
        try await ViewProbe.run { probe in
            let controller: CaptureController = probe.controller
            try ViewFixtures.seedTakes(controller, in: probe.root)

            for viewer in [CaptureController.ViewerMode.record, .playback] {
                controller.viewerMode = viewer
                controller.isCapturing = viewer == .record
                controller.playbackURL = viewer == .playback
                    ? probe.root.appendingPathComponent("a.mov") : nil
                let door: CGSize = probe.fittingSize(ComparePinControls())
                #expect((door.width > 0) == (viewer == .playback),
                        "\(viewer): the pin door is \(door.width)pt")
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
