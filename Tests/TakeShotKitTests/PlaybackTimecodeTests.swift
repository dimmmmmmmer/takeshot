import AVFoundation
import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// The playback timecode readouts. An operator matches these against the
/// camera's own display and against the sound report, so an off-by-one frame or
/// a drop-frame colon in the wrong place is a real defect: the numbers are used
/// to cut with, not to look at.
///
/// The math is driven directly rather than through a playing clip — the player's
/// position is a moving target and what is under test here is the arithmetic
/// from a start anchor, a rate and an elapsed offset.
@Suite @MainActor struct PlaybackTimecodeTests {
    @Test func withoutATimecodeTrackThePositionCountsFromZero() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.playbackStartTC = nil
            controller.playbackFPS = 25

            #expect(controller.playbackTC(atSeconds: 0) == "00:00:00:00")
            #expect(controller.playbackTC(atSeconds: 1) == "00:00:01:00")
            #expect(controller.playbackTC(atSeconds: 2.48) == "00:00:02:12")
            #expect(controller.playbackTC(atSeconds: 61.04) == "00:01:01:01")
            // a scrub that lands before zero must not produce a negative TC
            #expect(controller.playbackTC(atSeconds: -5) == "00:00:00:00")
        }
    }

    /// With a timecode track the readout is the file's start plus the elapsed
    /// frames — that is what makes a playback marker land at the same TC the
    /// camera's own log has.
    @Test func withATimecodeTrackThePositionIsAddedToTheStart() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.playbackStartTC = Timecode(hours: 10, minutes: 59,
                                                  seconds: 59, frames: 24, fps: 25)
            controller.playbackFPS = 25

            #expect(controller.playbackTC(atSeconds: 0) == "10:59:59:24")
            // rolls the whole way over: frames → seconds → minutes → hours
            #expect(controller.playbackTC(atSeconds: 0.04) == "11:00:00:00")
            #expect(controller.playbackTC(atSeconds: 4) == "11:00:03:24")
        }
    }

    /// 29.97 drop-frame keeps its punctuation and its dropped numbers: a
    /// readout printed as non-drop drifts against the camera by ~3.6 s an hour.
    @Test func dropFrameTimecodeKeepsItsNotation() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.playbackStartTC = Timecode(hours: 1, minutes: 0, seconds: 0,
                                                  frames: 0, fps: 30,
                                                  isDropFrame: true)
            controller.playbackFPS = 30_000.0 / 1001.0

            let atStart = controller.playbackTC(atSeconds: 0)
            #expect(atStart == "01:00:00;00", "drop-frame separator lost: \(atStart)")
            // a second of media at 29.97 is 29 whole frames, not 30 — the
            // second only turns over once the 30th has gone by
            #expect(controller.playbackTC(atSeconds: 1) == "01:00:00;29")
            #expect(controller.playbackTC(atSeconds: 1.02) == "01:00:01;00")
        }
    }

    /// The badge is read while a still is on screen, and a still leaves the
    /// AVPlayer empty — whose `currentTime()` is not a number. Zero, not a
    /// crash and not a stale position.
    @Test func theBadgeReadsZeroWhenNothingIsInTheAVPlayer() async throws {
        try await ControllerHarness.run { controller, _ in
            #expect(controller.player.currentItem == nil)
            controller.playbackStartTC = nil
            controller.playbackFPS = 25
            #expect(controller.playbackTimecodeText == "00:00:00:00")

            controller.playbackStartTC = Timecode(hours: 9, minutes: 30,
                                                  seconds: 0, frames: 5, fps: 25)
            #expect(controller.playbackTimecodeText == "09:30:00:05")
        }
    }

    /// A clip whose rate never loaded must not divide by zero or hand the
    /// operator a frame count of infinity.
    @Test func aMissingFrameRateFallsBackInsteadOfDividingByZero() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.playbackFPS = 0
            controller.playbackStartTC = nil
            #expect(controller.playbackTC(atSeconds: 3) == "00:00:03:00")
            #expect(controller.playbackTimecodeText == "00:00:00:00")
        }
    }
}

/// Grabbing a still. Stills are deliverables — they go into the report and to
/// the director — so the interesting part is not that a PNG appears but WHICH
/// frame it comes from and that a grab that cannot work says so instead of
/// quietly arming a grab of the live camera.
@Suite @MainActor struct PlaybackGrabTests {
    /// Files the grab wrote, so a test does not depend on the exact name.
    private func pngs(in root: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { $0.hasSuffix(".png") }
    }

    /// Playback mode with a clip loaded: the frame comes out of the FILE (via
    /// the image generator), never out of the preview — a baked preview LUT in
    /// a deliverable still is a look nobody asked for.
    @Test func grabbingInPlaybackWritesAStillNextToTheTakes() async throws {
        let media = try MediaFixtures.makeDirectory("grab-media")
        defer { try? FileManager.default.removeItem(at: media) }
        let clip = try await MediaFixtures.writeClip(
            at: media.appendingPathComponent("take.mov"), frames: 12)

        try await ControllerHarness.run { controller, root in
            MediaFixtures.silence(controller)
            defer { MediaFixtures.stopPlayback(controller) }

            controller.play(url: clip)
            #expect(controller.player.currentItem != nil)

            controller.grabFrame()
            // the highlight is the first thing the save path publishes, and it
            // clears itself after four seconds — poll on it rather than on a
            // directory listing that could be read after it expired
            let flashed = await ControllerWait.untilWritten {
                controller.recentlyAddedURL != nil
            }
            #expect(flashed, "no still was written to \(root.path)")
            let name = try #require(controller.recentlyAddedURL?.lastPathComponent)
            // project_cam_still_timecode — the project name is empty by default
            #expect(name.hasPrefix("A_still"), "unexpected still name: \(name)")
            #expect(pngs(in: root) == [name])
            #expect(controller.lastNotice != nil, "the operator is told where it went")
        }
    }

    /// A still in the player has no AVPlayer item behind it, so the grab falls
    /// through to the tap's current buffer. Before that fallback existed this
    /// silently armed a LIVE-camera grab and saved the wrong picture.
    @Test func grabbingAStillSavesWhatIsOnScreen() async throws {
        let media = try MediaFixtures.makeDirectory("grab-still")
        defer { try? FileManager.default.removeItem(at: media) }
        let source = try ControllerFixtures.writePNG(
            at: media.appendingPathComponent("source.png"), side: 24)

        try await ControllerHarness.run { controller, root in
            MediaFixtures.silence(controller)
            defer { MediaFixtures.stopPlayback(controller) }

            controller.play(url: source)
            await ControllerWait.untilWritten {
                controller.playbackTap.currentBuffer() != nil
            }
            #expect(controller.player.currentItem == nil)

            controller.grabFrame()
            let flashed = await ControllerWait.untilWritten {
                controller.recentlyAddedURL != nil
            }
            #expect(flashed, "the still on screen was not grabbed")
            #expect(pngs(in: root).count == 1)
            #expect(controller.lastError == nil)
        }
    }

    /// Playback mode with nothing decoded yet: the grab has to fail loudly.
    @Test func aGrabWithNothingLoadedReportsTheFailure() async throws {
        try await ControllerHarness.run { controller, root in
            MediaFixtures.silence(controller)
            controller.viewerMode = .playback
            controller.playbackURL = root.appendingPathComponent("nothing.mov")

            controller.grabFrame()
            #expect(controller.lastError == "Frame grab failed")
            #expect(pngs(in: root).isEmpty)
        }
    }

    /// Record mode with no signal: the same button must not pretend it worked.
    @Test func aGrabWithNoSignalSaysThereIsNoSignal() async throws {
        try await ControllerHarness.run { controller, root in
            #expect(controller.viewerMode == .record)
            #expect(!controller.isCapturing)

            controller.grabFrame()
            #expect(controller.lastError == L("no_signal"))
            #expect(pngs(in: root).isEmpty)
        }
    }
}
