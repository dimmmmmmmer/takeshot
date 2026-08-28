import CaptureCore
import CoreVideo
import Foundation
import Testing

@testable import TakeShotKit

/// **What each surface does when the comparison ends.**
///
/// The other half of `ControllerGridOutputTests`, and the half that is easy to
/// get wrong in a way nobody notices, because every mirror HOLDS its last frame:
/// `PlayoutFeeder` submits and the board goes on showing what it was given, an
/// NDI receiver keeps the last frame it got, a browser keeps the last one it
/// decoded. So a source going quiet is not a surface going blank — sending the
/// grid is only half the job, and the other half is making sure something takes
/// its place the moment it stops.
@Suite @MainActor struct ControllerGridExitTests {
    /// **The parked take comes back.**
    ///
    /// The mirrors hold their last frame, so a source going quiet is not a
    /// surface going blank: without this the board keeps the last four-up frame
    /// and the operator has no way to tell. Asserted at the wiring — the single
    /// player's tap owns the slot again — and at the tap's own idle latch, which
    /// is the thing that would silently defeat it (`PlaybackFrameTap.setRunning`).
    @Test func endingTheComparisonHandsTheSlotBackToTheParkedTake()
        async throws {
        try await GridOutputProbe.withGridAndBoard { controller, model, boards, _ in
            let board: FakePlayoutOutput = try #require(boards.latest)
            GridOutputProbe.deliver(model, tile: 0, code: 0x40)
            #expect(await ControllerWait.untilWritten {
                !board.displayed.isEmpty
            })

            controller.endSyncPlay()
            #expect(controller.syncPlay == nil)
            #expect(controller.mirrors.syncGrid == nil)
            #expect(controller.mirrors.syncGridComposer == nil)
            #expect(controller.playbackTap.displayFrameHandler != nil,
                    "the parked take never got the hardware output back")
            #expect(model.tiles.allSatisfy { $0.tap.displayFrameHandler == nil },
                    "a tile of an ended comparison is still feeding the mirrors")
        }
    }

    /// **A comparison with nothing parked underneath leaves the mirrors with
    /// nothing to show — so they are handed black rather than left frozen.**
    ///
    /// Reachable without trying: select four takes in the panel and compare them
    /// without opening one first. `PlayoutFeeder` holds its last frame, so the
    /// four-up picture would sit on the director's monitor looking exactly like
    /// a comparison somebody is running.
    @Test func endingWithNothingParkedBlanksTheOutputRatherThanFreezingIt()
        async throws {
        try await GridOutputProbe.withGridAndBoard(parked: false) { controller, model, boards, _ in
            let board: FakePlayoutOutput = try #require(boards.latest)
            #expect(controller.playbackURL == nil)
            GridOutputProbe.deliver(model, tile: 0, code: 0xF0)
            #expect(await ControllerWait.untilWritten {
                !board.displayed.isEmpty
            })
            let grid: CVPixelBuffer = try #require(board.displayed.last)
            let width = CVPixelBufferGetWidth(grid)
            let height = CVPixelBufferGetHeight(grid)
            #expect(GridOutputProbe.red(of: grid, atX: width / 4, y: height / 2) > 0x80,
                    "the grid never reached the board; this test is moot")

            controller.endSyncPlay()
            controller.mirrors.playout?.settle()
            let last: CVPixelBuffer = try #require(board.displayed.last)
            let level = GridOutputProbe.red(of: last, atX: width / 4, y: height / 2)
            #expect(level <= 8,
                    "the board is still holding the comparison: read \(level)")
        }
    }

    /// **A RAW clip parked under the comparison is pushed back**, rather than
    /// left to arrive when a view happens to be recreated.
    ///
    /// The RAW engine has no 60 Hz poll — it publishes when it decodes and when
    /// a sink mounts — so leaving it alone makes the director's monitor depend
    /// on SwiftUI rebuilding the player area. It does rebuild it, which is why
    /// this reads as a robustness case rather than as a bug; but "the picture
    /// comes back because a view was recreated" is not a rule the exit can hold
    /// on to, and this suite mounts no views at all, which is exactly the
    /// condition that makes the difference visible.
    @Test func endingOverARawClipPushesItsFrameBackToTheBoard() async throws {
        try await GridOutputProbe.withGridAndBoard(parked: false) { controller, model, boards, root in
            let board: FakePlayoutOutput = try #require(boards.latest)
            let (raw, _) = try RawClipFixtures.player(frames: 4, in: root)
            defer { controller.rawPlayer = nil }
            controller.playbackURL = raw.url
            controller.rawPlayer = raw
            // Decode one frame so there is something parked to push back. The
            // engine decodes off the main actor, so wait for the outcome.
            raw.seek(to: 0)
            #expect(await ControllerWait.untilWritten { raw.lastBuffer != nil },
                    "the RAW engine never decoded a frame; this test is moot")

            GridOutputProbe.deliver(model, tile: 0, code: 0xF0)
            #expect(await ControllerWait.untilWritten {
                !board.displayed.isEmpty
            }, "the grid never reached the board")
            let before: Int = board.displayed.count

            controller.endSyncPlay()
            #expect(await ControllerWait.untilWritten {
                board.displayed.count > before
            }, "the RAW clip under the comparison never reached the board again")
        }
    }

    /// A blanked grid never speaks again. The tiles stop on their own queues
    /// while the blank is issued from the main actor, so a compose already in
    /// flight could otherwise land after it and freeze the mirrors all over
    /// again — which is a race, and therefore the failure that shows up on
    /// somebody else's machine.
    @Test func aBlankedGridIgnoresAComposeThatWasAlreadyInFlight() throws {
        let collector = MediaFixtures.FrameCollector()
        let picture = SyncPlayGridPicture()
        picture.setOnDisplayFrame { collector.record($0[.decorated]) }
        picture.publish(MediaFixtures.pixelBuffer(level: 0x80, width: 64,
                                                  height: 36))
        #expect(collector.count == 1)

        #expect(picture.blank(), "a grid that had composed refused to blank")
        #expect(collector.count == 2)
        picture.publish(MediaFixtures.pixelBuffer(level: 0x90, width: 64,
                                                  height: 36))
        #expect(collector.count == 2,
                "a late compose reached the mirrors after the blank")
    }

    /// A grid that never composed anything has nothing to blank, and must not
    /// invent a raster to blank at.
    @Test func aGridThatNeverComposedHasNothingToBlank() {
        let picture = SyncPlayGridPicture()
        picture.setOnDisplayFrame { _ in }
        #expect(!picture.blank())
    }

    /// The rule the exit reads. Named on the controller rather than spelled
    /// inside `endSyncPlay`, and it is not obvious: three of the four states
    /// have a source that will publish and the fourth has none.
    @Test func theMirrorSourceRuleAnswersForEveryStateTheExitCanLeave()
        async throws {
        try await ControllerHarness.run { controller, root in
            MediaFixtures.silence(controller)
            let takes = try GridFixture.seedTakes(controller, in: root, count: 2)

            #expect(controller.viewerMode == .record)
            #expect(controller.mirrorsHaveASource, "the live signal is a source")

            controller.viewerMode = .playback
            #expect(!controller.mirrorsHaveASource,
                    "empty playback has a source to publish from")

            controller.playbackURL = takes[0].url
            #expect(controller.mirrorsHaveASource,
                    "a parked take is a source: its tap re-delivers")
        }
    }
}
