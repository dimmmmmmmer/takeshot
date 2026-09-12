import AVFoundation
import CaptureCore
import CoreVideo
import Foundation
import Testing

@testable import TakeShotKit

/// **The pinned reference, as a clip that plays.**
///
/// Owner: "реф видео из плейбека при пине на странице река не играет как видео
/// а остается стиллом". Pinning has always deep-copied one decoded frame, which
/// is right for a photo off the card and wrong for the thing an operator
/// actually pins — the take they just shot, to line the next setup up against.
///
/// What these hold is the app's half: which pins become a clip, when that clip
/// is allowed to decode (beside a camera, so never for nothing), that it loops
/// the operator's own range, and that unpinning takes the whole thing down.
@Suite @MainActor struct ModelReferenceClipTests {
    /// A take backed by a real playable file, loaded in the player and under
    /// review — the state an operator pins from.
    private func reviewing(_ controller: CaptureController, in folder: URL,
                           named name: String = "A001C001",
                           frames: Int = 30) async throws -> URL {
        let url = try await MediaFixtures.writeClip(
            at: folder.appendingPathComponent("\(name).mov"), frames: frames)
        controller.play(url: url)
        #expect(await ControllerWait.until { controller.viewerMode == .playback })
        // …and a frame decoded. Pinning reads `playbackTap.currentBuffer()`
        // and refuses when there is none, so a pin fired the instant the
        // player was handed a URL tests nothing but the race.
        #expect(await ControllerWait.until {
            controller.playbackTap.currentBuffer() != nil
        }, "the player never produced a frame to pin")
        return url
    }

    /// How many times the reference's tap has delivered, read the way the tap's
    /// own suite reads it.
    private func ticks(_ player: ReferenceClipPlayer) -> Int {
        player.tap.queue.sync { player.tap.tickCount }
    }

    /// A pin off a video take builds a player — and keeps the still, which is
    /// what the compare falls back to until the first decoded frame lands.
    @Test func pinningAVideoTakeBuildsAPlayerAndKeepsTheStillFallback()
        async throws {
        try await ControllerHarness.run { controller, root in
            _ = try await self.reviewing(controller, in: root)
            controller.pinReferenceFromCurrentFrame()

            #expect(controller.referencePinned)
            #expect(controller.viewerMode == .record)
            let player = try #require(controller.referencePlayer, """
                the pin produced no clip — the reference is the still this \
                report is about
                """)
            #expect(player.url.lastPathComponent == "A001C001.mov")
        }
    }

    /// A still and a RAW clip stay stills: neither is AVPlayer video, and a
    /// second engine for a picture that cannot move is a decode for nothing.
    @Test func pinningAStillOrARawClipStaysAStill() async throws {
        try await ControllerHarness.run { controller, root in
            let png = try ControllerFixtures.writePNG(
                at: root.appendingPathComponent("frame.png"))
            controller.play(url: png)
            #expect(await ControllerWait.until {
                controller.playbackURL == png
            })
            #expect(!controller.referenceCanPlay,
                    "a still would be pinned as a moving reference")

            let braw = root.appendingPathComponent("clip.braw")
            try Data([0]).write(to: braw)
            controller.playbackURL = braw
            #expect(!controller.referenceCanPlay,
                    "a RAW clip would be pinned as a moving reference")
        }
    }

    /// The clean feed hides the transport bar and says nothing about what a pin
    /// can be. Asking `transportBarKind` here would have frozen the reference
    /// for anyone working with the chrome off.
    @Test func aCleanFeedDoesNotStopAPinFromPlaying() async throws {
        try await ControllerHarness.run { controller, root in
            _ = try await self.reviewing(controller, in: root)
            controller.cleanFeed = true
            #expect(controller.transportBarKind == .none,
                    "the clean feed no longer hides the bar — premise gone")
            #expect(controller.referenceCanPlay, """
                a clean feed stopped the reference from playing, which is a \
                statement about the chrome deciding what a pin is
                """)
        }
    }

    /// **It decodes only while it is on screen.** A reference nobody is looking
    /// at, decoding beside a rolling camera, is what every other engine in this
    /// app refuses.
    @Test func theReferenceStopsDecodingWhenItIsNotOnScreen() async throws {
        try await ControllerHarness.run { controller, root in
            _ = try await self.reviewing(controller, in: root)
            controller.pinReferenceFromCurrentFrame()
            let player = try #require(controller.referencePlayer)
            #expect(controller.compareMode != .off, "pinning chose no mode")

            let running = await ControllerWait.until {
                self.ticks(player) > 0
            }
            #expect(running, "the reference never started decoding")

            controller.compareMode = .off
            let parked = self.ticks(player)
            let moved = await ControllerWait.until(
                { self.ticks(player) > parked + 1 }, timeout: .seconds(1))
            #expect(!moved, "the reference kept decoding with compare off")

            controller.compareMode = .wipe
            #expect(await ControllerWait.until { self.ticks(player) > parked },
                    "the reference did not come back when compare did")

            controller.viewerMode = .playback
            let parkedAgain = self.ticks(player)
            let movedAgain = await ControllerWait.until(
                { self.ticks(player) > parkedAgain + 1 }, timeout: .seconds(1))
            #expect(!movedAgain,
                    "the reference kept decoding with the viewer in playback")
        }
    }

    /// …and an A/B split counts as on screen. `compareComposite()` hands the
    /// pipeline `.off` for `.sideBySide` because a split composites nothing, so
    /// a rule written against the pipeline's own mode would stop the decode
    /// exactly where the reference has a surface to itself.
    @Test func anABSplitKeepsTheReferenceDecoding() async throws {
        try await ControllerHarness.run { controller, root in
            _ = try await self.reviewing(controller, in: root)
            controller.pinReferenceFromCurrentFrame()
            let player = try #require(controller.referencePlayer)
            controller.compareMode = .sideBySide

            let parked = self.ticks(player)
            #expect(await ControllerWait.until { self.ticks(player) > parked },
                    "the A/B split stopped the reference it is showing")
        }
    }

    /// **It loops the operator's own range, and never stops.**
    ///
    /// A reference that pauses at the end is a still again, which is the whole
    /// report. The range is the transport's own in/out — the one the operator
    /// marked and the sidecar records — rather than a second idea of "the
    /// interesting part".
    @Test func theReferenceLoopsItsMarkedRangeAndNeverStops() async throws {
        try await ControllerHarness.run { controller, root in
            _ = try await self.reviewing(controller, in: root, frames: 50)
            controller.transport.inPoint = 0.2
            controller.transport.outPoint = 0.5
            controller.pinReferenceFromCurrentFrame()
            let player = try #require(controller.referencePlayer)
            #expect(player.range.inPoint == 0.2)
            #expect(player.range.outPoint == 0.5)

            // **Sampled, not spot-checked.** A player looping to the HEAD of
            // the take passes through the marked range on its way back, so a
            // single reading inside the range says nothing at all — the claim
            // is about where it never goes. Seen: the first version of this
            // test read the time once and passed with the seek mutated to 0.
            var lowest = Double.infinity
            var highest = -Double.infinity
            var wrapped = false
            var previous = player.player.currentTime().seconds
            for _ in 0..<40 {
                try await Task.sleep(for: .milliseconds(50))
                let now = player.player.currentTime().seconds
                guard now.isFinite else { continue }
                lowest = min(lowest, now)
                highest = max(highest, now)
                if now < previous - 0.05 { wrapped = true }
                previous = now
            }
            #expect(wrapped, """
                the reference never went back in two seconds over a 0.3s range \
                — it is not looping at all
                """)
            #expect(lowest >= 0.15, """
                the reference dropped to \(lowest)s, below its 0.2s in point — \
                it loops to the head of the take rather than to the mark
                """)
            // **Half the take, not a hundred milliseconds past the mark.**
            //
            // The claim is that the reference turns round at the OPERATOR's
            // out point rather than at the end of the file, and this clip is
            // two seconds long — so a player honouring the 0.5s mark turns
            // round early and one ignoring it runs to 2.0.
            //
            // It read `<= 0.6` and that was a bet on scheduler latency, not a
            // statement about the app: the boundary observer fires on the main
            // queue and hops through a `Task` before the seek, and under the
            // ThreadSanitizer build CI runs, those two hops took 226 ms on a
            // loaded runner and the take rolled on through them. A margin that
            // small fails on the machine and not on the code.
            #expect(highest < 1, """
                the reference ran to \(highest)s of a 2s take — it loops at \
                the end of the file rather than at the mark
                """)
            #expect(player.isPlaying, "the reference froze at the end")
        }
    }

    /// Unpinning takes the player, the provider and the still down together. A
    /// provider left over a dead player would hold that player's last frame for
    /// ever — a still nobody pinned.
    @Test func unpinningTearsThePlayerDownAndClearsTheProvider() async throws {
        try await ControllerHarness.run { controller, root in
            _ = try await self.reviewing(controller, in: root)
            controller.pinReferenceFromCurrentFrame()
            let player = try #require(controller.referencePlayer)
            _ = await ControllerWait.until { self.ticks(player) > 0 }

            controller.unpinReference()
            #expect(controller.referencePlayer == nil)
            #expect(!controller.referencePinned)
            let parked = self.ticks(player)
            let moved = await ControllerWait.until(
                { self.ticks(player) > parked + 1 }, timeout: .seconds(1))
            #expect(!moved, "the unpinned reference is still decoding")
        }
    }

    /// A moving reference always implies a pinned one. The two answer different
    /// questions — "is there a B side" and "what kind" — and a state where the
    /// second is yes and the first is no has no meaning for any surface.
    @Test func aMovingReferenceAlwaysImpliesAPinnedOne() async throws {
        try await ControllerHarness.run { controller, root in
            @MainActor func holds() -> Bool {
                !controller.referenceIsMoving || controller.referencePinned
            }
            _ = try await self.reviewing(controller, in: root)
            #expect(holds())
            controller.pinReferenceFromCurrentFrame()
            #expect(holds())
            controller.viewerMode = .playback
            #expect(holds())
            controller.compareMode = .off
            #expect(holds())
            controller.unpinReference()
            #expect(holds())
            #expect(!controller.referenceIsMoving)
        }
    }
}
