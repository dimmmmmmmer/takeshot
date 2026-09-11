import CaptureCore
import Testing

@testable import TakeShotKit

/// **The transport, the way an editor's hands already know it** (owner: "как в
/// давинчи для транспорта по плейбеку хочу клавиши J K L и стрелочками влево
/// вправо чтобы по фрейму можно было двигаться, а через шифт и стрелочки на 5
/// фреймов к примеру, а стрелки вверх вниз к началу или к концу тейка меня
/// двигали").
///
/// The RAW engine is what most of this is measured on, and not for
/// convenience: it counts FRAMES, so "five frames" is a number a test can
/// read back rather than a position within a tolerance.
@Suite @MainActor struct ControllerTransportKeysTests {
    /// **The ladder.** Pressed again in the same direction it goes faster and
    /// stops at the top; pressed the other way it starts over at 1×, because
    /// J after L means "now go back" and not "go back eight times as fast".
    @Test func theShuttleLadderDoublesAndStartsOverTheOtherWay() {
        let next = CaptureController.nextShuttleRate
        #expect(next(0, true) == 1, "a stopped player starts at 1×")
        #expect(next(1, true) == 2)
        #expect(next(2, true) == 4)
        #expect(next(4, true) == 8)
        #expect(next(8, true) == 8, "the ladder ran off the top")
        #expect(next(0, false) == -1)
        #expect(next(-2, false) == -4)
        #expect(next(4, false) == -1, """
            J after L came out at \(next(4, false))× — it has to start over
            """)
        #expect(next(-4, true) == 1)
    }

    /// **Five frames is five frames**, and one is one — on the engine that
    /// counts them.
    @Test func theArrowsMoveTheRawEngineByFrames() async throws {
        try await ControllerHarness.run { controller, root in
            MediaFixtures.silence(controller)
            let (raw, _) = try RawClipFixtures.player(frames: 24, in: root)
            defer { controller.rawPlayer = nil }
            controller.viewerMode = .playback
            // `isReviewingClip` is what the edge and shuttle keys are gated on
            // and it asks for a clip in the SINGLE player's slot too — which
            // is what opening a RAW clip really leaves behind.
            controller.playbackURL = raw.url
            controller.rawPlayer = raw
            raw.seek(to: 0)

            controller.stepPlayback(byFrames: CaptureController.frameJump)
            #expect(raw.currentFrame == 5, """
                ⇧→ left the playhead on frame \(raw.currentFrame)
                """)
            controller.stepPlayback(forward: false)
            #expect(raw.currentFrame == 4, "→ is one frame")
            controller.stepPlayback(byFrames: -CaptureController.frameJump)
            #expect(raw.currentFrame == 0, "⇧← ran past the head of the clip")
        }
    }

    /// **↑ and ↓ go to the clip's own ends** — and to the marked range's ends
    /// when there is one, because that is what "the take" means once an
    /// operator has trimmed it.
    @Test func theEdgeKeysGoToTheHeadAndTail() async throws {
        try await ControllerHarness.run { controller, root in
            MediaFixtures.silence(controller)
            let (raw, _) = try RawClipFixtures.player(frames: 24, in: root)
            defer { controller.rawPlayer = nil }
            controller.viewerMode = .playback
            // `isReviewingClip` is what the edge and shuttle keys are gated on
            // and it asks for a clip in the SINGLE player's slot too — which
            // is what opening a RAW clip really leaves behind.
            controller.playbackURL = raw.url
            controller.rawPlayer = raw

            controller.goToPlaybackEdge(end: true)
            #expect(raw.currentFrame == 23, """
                ↓ landed on frame \(raw.currentFrame) of a 24-frame clip
                """)
            controller.goToPlaybackEdge(end: false)
            #expect(raw.currentFrame == 0)

            raw.seek(to: 6)
            raw.toggleRangePoint(out: false)
            raw.seek(to: 18)
            raw.toggleRangePoint(out: true)
            controller.goToPlaybackEdge(end: false)
            #expect(raw.currentFrame == 6, """
                ↑ went past the IN point to frame \(raw.currentFrame)
                """)
            controller.goToPlaybackEdge(end: true)
            #expect(raw.currentFrame == 18, """
                ↓ went past the OUT point to frame \(raw.currentFrame)
                """)
        }
    }

    /// **An engine with no reverse says so by stepping**, rather than
    /// pretending: the RAW decoder plays one way, so J moves a frame back.
    @Test func theShuttleStepsBackWhereThereIsNoReverse() async throws {
        try await ControllerHarness.run { controller, root in
            MediaFixtures.silence(controller)
            let (raw, _) = try RawClipFixtures.player(frames: 24, in: root)
            defer { controller.rawPlayer = nil }
            controller.viewerMode = .playback
            // `isReviewingClip` is what the edge and shuttle keys are gated on
            // and it asks for a clip in the SINGLE player's slot too — which
            // is what opening a RAW clip really leaves behind.
            controller.playbackURL = raw.url
            controller.rawPlayer = raw
            raw.seek(to: 10)

            controller.shuttlePlayback(forward: false)
            #expect(!raw.isPlaying, "the RAW engine was asked to play backwards")
            #expect(raw.currentFrame == 9, """
                J left the playhead on frame \(raw.currentFrame)
                """)
            controller.shuttlePlayback(forward: true)
            #expect(raw.isPlaying, "L did not start the RAW engine")
            controller.stopShuttle()
            #expect(!raw.isPlaying, "K did not stop it")
        }
    }
}
