import AVFoundation
import CaptureCore
import CoreVideo
import Foundation
import Testing

@testable import TakeShotKit

/// Opening something in the player. Everything here is driven against media
/// this build wrote itself, because the failure these tests exist to catch is
/// the one that only shows on set: a take that records fine and then comes back
/// with the wrong badges, no start timecode, or — worse — routed to the wrong
/// engine, so the operator's review layer is blank while the camera rolls.
///
/// `play(url:)` is a four-way switch (AVPlayer clip, still, RAW engine,
/// CinemaDNG folder) and every branch resets state the previous one set; the
/// suite walks all four and the transitions between them.
@Suite @MainActor struct PlaybackLoadTests {
    /// The badges above the player come out of the file, not out of the take
    /// record: an offloaded clip re-opened later has no take behind it.
    @Test func loadingATakeFillsThePlayerBadgesFromTheFileItself() async throws {
        let media = try MediaFixtures.makeDirectory("playback-badges")
        defer { try? FileManager.default.removeItem(at: media) }
        let clip = try await MediaFixtures.writeClip(
            at: media.appendingPathComponent("take.mov"))

        try await ControllerHarness.run { controller, _ in
            MediaFixtures.silence(controller)
            defer { MediaFixtures.stopPlayback(controller) }

            controller.play(url: clip)
            #expect(controller.playbackURL == clip)
            #expect(controller.viewerMode == .playback)
            #expect(controller.player.currentItem != nil)

            // the badges are loaded off the main actor once the tracks resolve
            let loaded = await ControllerWait.untilWritten {
                controller.playbackFormatText != nil
            }
            #expect(loaded, "the clip's format never loaded")

            #expect(controller.playbackFormatText == "180p25")
            #expect(abs(controller.playbackFPS - 25) < 0.1)
            let aspect = try #require(controller.playbackAspect)
            #expect(abs(aspect - 320.0 / 180.0) < 0.01)
        }
    }

    /// The file's start timecode is the anchor every playback readout and every
    /// playback marker is measured from. The media is fine — `TimecodeReader`
    /// reads the very same track — so this is purely about the controller
    /// getting it out of the file.
    ///
    /// Known issue: `firstTimecodeSample` in `CaptureController+Playback` takes
    /// the first sample buffer of the timecode track and gives up when it has no
    /// data. The first buffer of a tc32 track IS an empty marker (proven below),
    /// so the anchor is never set and playback counts from 00:00:00:00 instead
    /// of the camera's timecode. `TimecodeReader.startTimecode(of:)` in
    /// CaptureCore is the same read, done correctly.
    @Test func theClipsOwnStartTimecodeBecomesThePlaybackAnchor() async throws {
        let media = try MediaFixtures.makeDirectory("playback-anchor")
        defer { try? FileManager.default.removeItem(at: media) }
        let clip = try await MediaFixtures.writeClip(
            at: media.appendingPathComponent("take.mov"), frames: 12)

        // the timecode is in the file and readable — this is not a bad fixture
        let onDisk = await TimecodeReader.startTimecode(of: AVURLAsset(url: clip))
        #expect(onDisk?.description == MediaFixtures.startTimecode.description)

        try await ControllerHarness.run { controller, _ in
            MediaFixtures.silence(controller)
            defer { MediaFixtures.stopPlayback(controller) }

            controller.play(url: clip)
            await ControllerWait.untilWritten { controller.playbackFormatText != nil }

            // The first sample of a tc32 track is an empty marker;
            // firstTimecodeSample now walks past it to the anchor, so our own
            // recordings play back counting from the take's real start TC.
            let anchored = await ControllerWait.untilWritten {
                controller.playbackStartTC != nil
            }
            #expect(anchored, "playback has no timecode anchor")
            #expect(controller.playbackStartTC?.description
                    == MediaFixtures.startTimecode.description)
        }
    }

    /// A 29.97 clip has to come back at its real rate: the transport converts
    /// seconds to frames with it, so a rounded 30 puts the readout a frame
    /// further out the longer the clip runs.
    @Test func aFractionalRateClipReportsItsRealRate() async throws {
        let media = try MediaFixtures.makeDirectory("playback-df")
        defer { try? FileManager.default.removeItem(at: media) }
        let startTC = Timecode(hours: 1, minutes: 0, seconds: 0, frames: 0,
                               fps: 30, isDropFrame: true)
        let clip = try await MediaFixtures.writeClip(
            at: media.appendingPathComponent("df.mov"),
            frameRate: 30_000.0 / 1001.0, timecodeFPS: 30, frames: 30,
            startTimecode: startTC)

        try await ControllerHarness.run { controller, _ in
            MediaFixtures.silence(controller)
            defer { MediaFixtures.stopPlayback(controller) }

            controller.play(url: clip)
            let loaded = await ControllerWait.untilWritten {
                controller.playbackFormatText != nil
            }
            #expect(loaded)
            #expect(abs(controller.playbackFPS - 29.97) < 0.2,
                    "playbackFPS=\(controller.playbackFPS)")
            #expect(controller.playbackFormatText?.hasPrefix("180p") == true,
                    "format badge=\(controller.playbackFormatText ?? "nil")")
        }
    }

    /// Our own file carrying com.takeshot.lut already has the look in it. The
    /// preview LUT must switch itself off for that clip, or the operator sees
    /// the grade twice.
    @Test func aClipWithABakedLookIsNotGradedTwice() async throws {
        let media = try MediaFixtures.makeDirectory("playback-baked")
        defer { try? FileManager.default.removeItem(at: media) }
        let baked = try await MediaFixtures.writeClip(
            at: media.appendingPathComponent("baked.mov"),
            frames: 12, bakedLUTName: "show.cube")
        let clean = try await MediaFixtures.writeClip(
            at: media.appendingPathComponent("clean.mov"), frames: 12)

        try await ControllerHarness.run { controller, _ in
            MediaFixtures.silence(controller)
            defer { MediaFixtures.stopPlayback(controller) }

            controller.play(url: baked)
            let detected = await ControllerWait.untilWritten {
                controller.playbackFileHasBakedLUT
            }
            #expect(detected, "the com.takeshot.lut tag was not seen on the file")

            // and loading a clean clip clears it again — the flag is per clip
            controller.play(url: clean)
            #expect(!controller.playbackFileHasBakedLUT)
            await ControllerWait.untilWritten { controller.playbackFormatText != nil }
            #expect(!controller.playbackFileHasBakedLUT)
        }
    }

    /// Stills go through the tap like video (SwiftUI's Image is color-managed
    /// differently and never matched the player), so loading one has to leave
    /// the tap holding a buffer and the AVPlayer empty.
    @Test func aStillIsHandedToTheTapAndNotToTheAVPlayer() async throws {
        let media = try MediaFixtures.makeDirectory("playback-still")
        defer { try? FileManager.default.removeItem(at: media) }
        let still = try ControllerFixtures.writePNG(
            at: media.appendingPathComponent("grab.png"), side: 48)

        try await ControllerHarness.run { controller, _ in
            MediaFixtures.silence(controller)
            defer { MediaFixtures.stopPlayback(controller) }

            controller.play(url: still)
            #expect(controller.player.currentItem == nil,
                    "a photo must not be pushed into the AVPlayer")

            await ControllerWait.untilWritten {
                controller.playbackTap.currentBuffer() != nil
            }
            let buffer = try #require(controller.playbackTap.currentBuffer())
            #expect(CVPixelBufferGetWidth(buffer) == 48)
            #expect(CVPixelBufferGetHeight(buffer) == 48)
            #expect(controller.playbackFormatText == "48p")
            #expect(controller.playbackAspect == 1)
            #expect(controller.viewerMode == .playback)
        }
    }

    /// R3D is recognised and reported, not silently ignored: an operator who
    /// double-clicks a RED clip must be told why nothing happened.
    @Test func anR3DClipReportsItsMissingDecoder() async throws {
        let media = try MediaFixtures.makeDirectory("playback-r3d")
        defer { try? FileManager.default.removeItem(at: media) }
        let clip = media.appendingPathComponent("A001_C001.r3d")
        try Data([0x00]).write(to: clip)

        try await ControllerHarness.run { controller, _ in
            MediaFixtures.silence(controller)
            defer { MediaFixtures.stopPlayback(controller) }

            controller.play(url: clip)
            #expect(controller.rawPlayer == nil)
            #expect(controller.rawPlayerError == L("r3d_not_supported"))
            #expect(controller.playbackURL == clip)
            #expect(controller.viewerMode == .playback)
            #expect(controller.player.currentItem == nil,
                    "a RAW clip must not also be handed to the AVPlayer")
        }
    }

    /// A .braw the bridge cannot open (no SDK in this build, or a damaged file)
    /// has to surface its reason the same way.
    @Test func aBRAWFileThatCannotBeOpenedSurfacesTheReason() async throws {
        let media = try MediaFixtures.makeDirectory("playback-braw")
        defer { try? FileManager.default.removeItem(at: media) }
        let clip = try MediaFixtures.writeCorruptClip(
            at: media.appendingPathComponent("A001.braw"))

        try await ControllerHarness.run { controller, _ in
            MediaFixtures.silence(controller)
            defer { MediaFixtures.stopPlayback(controller) }

            controller.play(url: clip)
            #expect(controller.rawPlayer == nil)
            let reason = try #require(controller.rawPlayerError)
            #expect(!reason.isEmpty)
        }
    }

    /// Going back to an AVPlayer clip after a RAW failure has to clear the
    /// error and the engine — the sticky version of this left the player
    /// showing "cannot open" over a take that was playing fine.
    @Test func loadingATakeAfterARawFailureClearsTheError() async throws {
        let media = try MediaFixtures.makeDirectory("playback-recover")
        defer { try? FileManager.default.removeItem(at: media) }
        let raw = media.appendingPathComponent("A001.r3d")
        try Data([0x00]).write(to: raw)
        let clip = try await MediaFixtures.writeClip(
            at: media.appendingPathComponent("take.mov"), frames: 12)

        try await ControllerHarness.run { controller, _ in
            MediaFixtures.silence(controller)
            defer { MediaFixtures.stopPlayback(controller) }

            controller.play(url: raw)
            #expect(controller.rawPlayerError != nil)

            controller.play(url: clip)
            #expect(controller.rawPlayerError == nil)
            #expect(controller.rawPlayer == nil)
            #expect(controller.player.currentItem != nil)
        }
    }

    /// The routing table itself: which extensions go to our own engine, and
    /// which are stills. A codec that quietly moves between the two lists
    /// changes what the player does with every file of that kind.
    @Test func theRawExtensionListIsExactlyTheEnginesWeHave() {
        #expect(CaptureController.rawExtensions == ["braw", "r3d"])
        // .dng is a still on its own and a clip only as a folder of frames
        #expect(CaptureController.imageExtensions.contains("dng"))
        #expect(!CaptureController.rawExtensions.contains("dng"))
        #expect(!CaptureController.rawExtensions.contains("mov"))
    }

    /// A CinemaDNG clip is a folder, and it is recognised by what is inside it:
    /// an empty folder, or one holding anything else, is not a clip.
    @Test func aCinemaDNGFolderIsRecognisedByItsFramesNotItsName() throws {
        let root = try MediaFixtures.makeDirectory("playback-dng")
        defer { try? FileManager.default.removeItem(at: root) }

        let empty = root.appendingPathComponent("empty.dng")
        try FileManager.default.createDirectory(at: empty,
                                                withIntermediateDirectories: true)
        #expect(!CaptureController.isCinemaDNGFolder(empty),
                "an empty folder is not a clip however it is named")

        let sequence = root.appendingPathComponent("A001")
        try FileManager.default.createDirectory(at: sequence,
                                                withIntermediateDirectories: true)
        try Data([0x00]).write(to: sequence.appendingPathComponent("0001.dng"))
        #expect(CaptureController.isCinemaDNGFolder(sequence))

        let file = root.appendingPathComponent("single.dng")
        try Data([0x00]).write(to: file)
        #expect(!CaptureController.isCinemaDNGFolder(file),
                "a file is never a sequence folder")
        #expect(!CaptureController.isCinemaDNGFolder(
            root.appendingPathComponent("gone")))
    }

    /// Instant replay is a video-assist button: it always means the newest
    /// take, from the top, looping — not whatever happens to be selected.
    @Test func instantReplayLoadsTheFreshestTakeAndArmsTheLoop() async throws {
        try await ControllerHarness.run { controller, root in
            MediaFixtures.silence(controller)
            defer { MediaFixtures.stopPlayback(controller) }

            // nothing recorded yet: the button is inert rather than crashing
            controller.instantReplay()
            #expect(controller.playbackURL == nil)
            #expect(!controller.replayLoopRequested)

            let older = ControllerFixtures.take(
                named: "A001_C001", in: root,
                recordedAt: Date(timeIntervalSinceNow: -600))
            let newest = ControllerFixtures.take(
                named: "A001_C002", in: root, clip: 2,
                recordedAt: Date(timeIntervalSinceNow: -60))
            try await MediaFixtures.writeClip(at: older.url, frames: 8)
            try await MediaFixtures.writeClip(at: newest.url, frames: 8)
            controller.takes = [older, newest]

            controller.instantReplay()
            #expect(controller.playbackURL == newest.url)
            #expect(controller.replayLoopRequested,
                    "the transport is told to loop when the clip loads")
            #expect(controller.viewerMode == .playback)
        }
    }
}
