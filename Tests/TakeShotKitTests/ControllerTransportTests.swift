import AVFoundation
import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// The menu bar drives the transport with one set of items, but a clip is played
/// by one of two engines — AVPlayer or our own RAW engine — and each has its own
/// transport bar wired straight to it. The router in `+Transport` is what the
/// menu talks to instead, and the failure it prevents is the quiet one: an item
/// that works on a ProRes take and does nothing at all on a BRAW one.
@Suite @MainActor struct ControllerTransportTests {
    @Test func reviewingIsAClipLoadedAndOnScreen() async throws {
        try await ControllerHarness.run { controller, root in
            #expect(!controller.isReviewingClip, "record mode is not review")

            controller.playbackURL = root.appendingPathComponent("a.mov")
            #expect(!controller.isReviewingClip,
                    "a loaded clip the viewer is not showing is not review")

            controller.viewerMode = .playback
            #expect(controller.isReviewingClip)

            controller.playbackURL = nil
            #expect(!controller.isReviewingClip)
        }
    }

    @Test func loopPointsGoToTheAVPlayerTransport() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.toggleLoopPoint(out: false)
            #expect(controller.transport.inPoint == 0)

            controller.toggleLoopPoint(out: true)
            // in and out at the same position cannot both stand
            #expect(controller.transport.outPoint == 0)
            #expect(controller.transport.inPoint == nil)

            // clicking the same point again clears it
            controller.toggleLoopPoint(out: true)
            #expect(controller.transport.outPoint == nil)
        }
    }

    /// With a RAW clip loaded the same call has to reach the RAW engine — and
    /// must not quietly set a loop point on the idle AVPlayer transport instead.
    @Test func loopPointsGoToTheRawEngineWhenItHasTheClip() async throws {
        try await ControllerHarness.run { controller, root in
            let raw = try ViewFixtures.rawPlayer(in: root)
            controller.rawPlayer = raw
            defer { controller.rawPlayer = nil }

            controller.toggleLoopPoint(out: false)
            #expect(raw.inFrame == 0)
            #expect(controller.transport.inPoint == nil,
                    "the AVPlayer transport took a RAW clip's loop point")

            controller.toggleLoopPoint(out: true)
            #expect(raw.outFrame == 0)
        }
    }

    @Test func loopingReadsAndWritesWhicheverEngineIsPlaying() async throws {
        try await ControllerHarness.run { controller, root in
            controller.transport.isLooping = false
            #expect(!controller.loopPlayback)
            controller.loopPlayback = true
            #expect(controller.transport.isLooping)

            let raw = try ViewFixtures.rawPlayer(in: root)
            raw.isLooping = false
            controller.rawPlayer = raw
            defer { controller.rawPlayer = nil }

            #expect(!controller.loopPlayback, "still reading the AVPlayer loop")
            controller.loopPlayback = true
            #expect(raw.isLooping)
            #expect(controller.transport.isLooping,
                    "the AVPlayer loop flag must not be disturbed")
        }
    }

    /// Play/pause and the skips on a real clip: the menu item has to stop a
    /// running clip and start a stopped one, and land the playhead where it says.
    @Test func playPauseAndSkipDriveTheLoadedClip() async throws {
        try await ControllerHarness.run { controller, root in
            let url = root.appendingPathComponent("clip.mov")
            try await MediaFixtures.writeClip(at: url, frames: 50)
            MediaFixtures.silence(controller)
            defer { MediaFixtures.stopPlayback(controller) }

            controller.play(url: url) // play(url:) starts it rolling
            await ControllerWait.untilWritten { controller.player.rate != 0 }

            controller.togglePlayPause()
            #expect(controller.player.rate == 0, "the clip did not pause")

            controller.togglePlayPause()
            #expect(await ControllerWait.untilWritten {
                controller.player.rate != 0
            }, "the clip did not resume")

            controller.togglePlayPause()
            controller.skipPlayback(bySeconds: 1)
            #expect(await ControllerWait.untilWritten {
                controller.player.currentTime().seconds >= 0.95
            }, "the skip landed at \(controller.player.currentTime().seconds)s")
        }
    }
}
