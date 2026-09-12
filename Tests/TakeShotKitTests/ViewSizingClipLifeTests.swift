import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// **A review geometry belongs to the clip it was set on**, and a take whose
/// framing is already in its pixels is not reframed by the first control the
/// operator touches.
///
/// Two defects with one shape. The playback set was per SESSION: reframe take
/// A, open take B, and B inherited A's geometry — the identical defect
/// `TransportModel+ClipRanges` documents for the in/out marks. And the refusal
/// that keeps a baked take from being reframed twice reads "nothing has been
/// set for this clip", so a single nudge turned it off for the rest of the
/// session, on every clip after it.
@Suite @MainActor struct ViewSizingClipLifeTests {
    /// A CinemaDNG "clip" — the engine opens the folder and never decodes a
    /// frame, which is the cheapest real `play(url:)` in the suite.
    private func clip(in media: URL, named name: String) throws -> URL {
        let sequence = media.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: sequence,
                                                withIntermediateDirectories: true)
        try Data("frame".utf8).write(
            to: sequence.appendingPathComponent("0001.dng"))
        return sequence
    }

    /// Opening a clip clears the geometry that was set on the last one.
    @Test func areframeDoesNotFollowTheOperatorToTheNextClip() async throws {
        let media = MediaFixtures.scratchDirectory("SizingClipLife")
        defer { try? FileManager.default.removeItem(at: media) }
        let first = try clip(in: media, named: "A001")
        let second = try clip(in: media, named: "A002")

        try await ControllerHarness.run { controller, _ in
            MediaFixtures.silence(controller)
            defer { MediaFixtures.stopPlayback(controller) }

            controller.play(url: first)
            controller.rawPlayer?.pause()
            controller.viewerMode = .playback
            controller.punchInLevel = 3
            // `liveAssist`, not `assist`: a slider write is a DRAFT until the
            // debounce settles it, and this is the value the surfaces have.
            #expect(controller.liveAssist.playbackSizing != nil,
                    "the reframe never landed, so this proves nothing")

            controller.play(url: second)
            controller.rawPlayer?.pause()
            #expect(controller.liveAssist.playbackSizing == nil,
                    "the last clip's reframe landed on this one")
        }
    }

    /// …and so does the answer about what the FILE already carries. It was set
    /// only on the video branch, so a baked take followed by a RAW clip left
    /// the panel claiming a framing this app never wrote into it.
    @Test func aBakedFramingIsForgottenWithItsClip() async throws {
        let media = MediaFixtures.scratchDirectory("SizingClipBaked")
        defer { try? FileManager.default.removeItem(at: media) }
        let raw = try clip(in: media, named: "A003")

        try await ControllerHarness.run { controller, _ in
            MediaFixtures.silence(controller)
            defer { MediaFixtures.stopPlayback(controller) }
            controller.playbackFileHasBakedSizing = true
            controller.playbackFileHasBakedLUT = true

            controller.play(url: raw)
            controller.rawPlayer?.pause()
            #expect(!controller.playbackFileHasBakedSizing,
                    "a RAW clip inherited the last take's baked framing")
            #expect(!controller.playbackFileHasBakedLUT,
                    "a RAW clip inherited the last take's baked look")
        }
    }

    /// **The first nudge on a baked take starts from the picture on screen.**
    ///
    /// The surfaces show identity over such a take, and the panel's own notice
    /// invites the operator to "move a control to reframe it anyway" — so an
    /// edit seeded from the LIVE nine would flip it a second time on the one
    /// action the UI recommends.
    @Test func theFirstNudgeOnABakedTakeDoesNotBringTheLiveGeometryWithIt()
        async throws {
        try await ControllerHarness.run { controller, _ in
            controller.assist.flipH = true
            controller.viewerMode = .playback
            controller.playbackFileHasBakedSizing = true

            controller.punchInLevel = 2

            let set = try #require(controller.liveAssist.playbackSizing)
            #expect(set.zoom == 2, "the nudge itself did not land")
            #expect(!set.flipH,
                    "the live flip came with it and the take is flipped twice")
        }
    }
}
