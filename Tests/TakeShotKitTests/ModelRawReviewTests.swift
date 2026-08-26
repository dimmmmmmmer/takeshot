import CaptureCore
import CoreVideo
import Foundation
import Testing

@testable import TakeShotKit

/// Reviewing a RAW clip: the decode/present loop, where a loop restarts, and
/// what the player says when a frame will not decode.
///
/// None of this had ever run. Every RAW fixture the suites had was a folder of
/// files no decoder opens, which is enough to construct the engine and measure
/// its arithmetic and nothing more — so `RawPlayback+PlayLoop` and
/// `RawPlayback+Scopes` were 43 % and 10 % covered, and the only arm that ever
/// executed was the failure one. `RawClipFixtures` makes a clip that really
/// decodes (see the note there), and what it unlocks is the review path a DIT
/// spends the day in: the picture following the playhead, the loop points, and
/// a card going bad mid-clip.
@Suite @MainActor struct ModelRawReviewTests {
    private func scratch() throws -> URL {
        try MediaFixtures.makeDirectory("raw-review")
    }

    // MARK: - the picture follows the playhead

    /// A paused seek shows THAT frame. The loop publishes the index it decoded
    /// and presents the buffer it decoded, and nothing else in the app checks
    /// that those are the same one — a swap there is a player whose readout
    /// disagrees with its picture by a frame, which is exactly the difference a
    /// focus check is looking for.
    @Test func aPausedSeekShowsTheFrameThePlayheadNames() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, presented) = try RawClipFixtures.player(frames: 12, in: root)

        model.seek(to: 7)
        #expect(await ControllerWait.untilWritten { presented.count > 0 })
        #expect(model.currentFrame == 7)
        #expect(presented.last == 7,
                "the playhead says 7 and frame \(presented.last as Any) is on screen")
        // and the still the operator can grab out of the clip is that frame too
        let onScreen = try #require(model.currentBuffer())
        #expect(RawClipFixtures.frameIndex(of: onScreen) == 7)
    }

    /// A seek past either end lands inside the clip rather than on a frame that
    /// does not exist — the scrub bar hands this engine wall-clock seconds and
    /// the ±5 buttons hand it more than the clip is long.
    @Test func aSeekOutsideTheClipIsClampedIntoIt() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, presented) = try RawClipFixtures.player(frames: 6, in: root)

        model.seek(to: 99)
        #expect(model.currentFrame == 5)
        model.skip(seconds: -60)
        #expect(model.currentFrame == 0)
        #expect(await ControllerWait.untilWritten { presented.last == 0 })
    }

    /// The first surface to mount decodes the poster frame; a second one is
    /// handed the frame already on screen. A scopes window or a fullscreen
    /// player opening mid-review must not cost a decode, and must not black
    /// out the picture while it takes one.
    @Test func aSecondMountCostsNoDecode() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, presented) = try RawClipFixtures.player(frames: 6, in: root)

        let first = MetalPreviewLayer()
        model.addSink(first)
        #expect(await ControllerWait.untilWritten { presented.count == 1 },
                "the first mount did not decode the poster frame")
        #expect(presented.last == 0)

        let second = MetalPreviewLayer()
        model.addSink(second)
        // full budget on purpose: this waits for a decode that must NOT happen
        _ = await ControllerWait.until({ presented.count > 1 },
                                       timeout: .milliseconds(500))
        #expect(presented.count == 1,
                "the second mount decoded again instead of re-presenting")
        model.removeSink(first)
        model.removeSink(second)
    }

    // MARK: - playing through

    /// Play runs to the end of the clip and stops, with nothing to report. The
    /// loop's normal exit — as against the failure one below, which used to be
    /// indistinguishable from it.
    @Test func playbackReachesTheEndAndStopsWithNothingToReport() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, presented) = try RawClipFixtures.player(frames: 12, in: root)

        model.togglePlay()
        #expect(model.isPlaying)
        #expect(await ControllerWait.untilWritten { !model.isPlaying },
                "playback never finished")
        #expect(model.playbackError == nil,
                "reaching the end was reported as a failure")
        #expect(presented.count > 1, "nothing was ever shown")
        // the readout and the picture stop on the SAME frame: the loop
        // publishes the index it decoded, and nothing else pairs the two
        #expect(model.currentFrame == presented.last,
                "the readout says \(model.currentFrame) over \(presented.last as Any)")
        // real-time mapping may skip frames on a slow machine, never repeat or
        // go back: a clip that stutters backwards is a decoder bug that reads
        // as a bad card
        let shown = presented.all
        #expect(zip(shown, shown.dropFirst()).allSatisfy { $0 < $1 },
                "the clip did not run forwards: \(shown)")
    }

    /// A frame that will not decode is a sentence about the card, and the
    /// player says it. Pausing silently — which is what it used to do — is
    /// exactly what reaching the end looks like, so the operator's read is
    /// "that clip is short" rather than "that card is bad".
    @Test func aFrameThatWillNotDecodeIsReportedRatherThanLookingLikeTheEnd()
        async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        // From frame 4 to the end, not frame 4 alone: the play loop skips
        // frames it cannot keep up with, so a single broken frame asks the
        // machine to land on it rather than asking the app anything.
        let (model, _) = try RawClipFixtures.player(frames: 12, in: root,
                                                    brokenFrom: 4)
        let toasts = RawClipFixtures.Toasts()
        model.onPlaybackError = { toasts.record($0) }

        model.play()
        #expect(await ControllerWait.untilWritten { !model.isPlaying })
        let reported = try #require(model.playbackError,
                                    "a corrupt frame stopped the clip in silence")
        #expect(reported == L("raw_decode_stopped"))
        #expect(toasts.all == [reported], "the toast and the sticky glyph disagree")
    }

    /// …but the LAST frame refusing to decode is not a failure, it is the end.
    /// The two are told apart by position and nothing else, and getting that
    /// wrong would put a red glyph on every clip whose tail is short a frame.
    @Test func aClipWhoseLastFrameWillNotDecodeHasSimplyEnded() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, _) = try RawClipFixtures.player(frames: 6, in: root,
                                                    brokenAt: 5)

        model.play()
        #expect(await ControllerWait.untilWritten { !model.isPlaying })
        #expect(model.playbackError == nil,
                "the end of the clip was reported as a decode failure")
    }

    /// Pressing play after a failure clears the message: the operator is asking
    /// again, and a stale complaint beside a running picture is worse than none.
    @Test func playingAgainClearsTheLastFailure() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        // From frame 4 to the end, not frame 4 alone: the play loop skips
        // frames it cannot keep up with, so a single broken frame asks the
        // machine to land on it rather than asking the app anything.
        let (model, _) = try RawClipFixtures.player(frames: 12, in: root,
                                                    brokenFrom: 4)

        model.play()
        #expect(await ControllerWait.untilWritten { model.playbackError != nil })
        #expect(await ControllerWait.untilWritten { !model.isPlaying })

        model.seek(to: 0)
        model.play()
        defer { model.pause() }
        #expect(model.playbackError == nil)
    }

    // MARK: - the loop points

    /// A loop with an in point resumes at the IN POINT, not at the head of the
    /// clip. The same bug the AVPlayer transport had (owner item 38): the loop
    /// was enforced at the out point alone, so a clip marked up for one line of
    /// dialogue replayed the whole lead-in every time round.
    @Test func aLoopWithAnInPointResumesAtTheInPoint() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, presented) = try RawClipFixtures.player(frames: 16, in: root)
        defer { model.pause() }

        model.currentFrame = 3
        model.toggleRangePoint(out: false)   // in at 3
        model.currentFrame = 8
        model.toggleRangePoint(out: true)    // out at 8
        #expect((model.inFrame, model.outFrame) == (3, 8))

        model.isLooping = true
        model.play()
        #expect(await ControllerWait.untilWritten { Self.restart(in: presented.all) != nil },
                "the loop never came round: \(presented.all)")
        let restart = try #require(Self.restart(in: presented.all))
        #expect(restart == 3, "the loop restarted at \(restart), not at the in point")
        #expect(presented.all.allSatisfy { $0 <= 8 },
                "playback ran past the out point: \(presented.all)")
    }

    /// With no range marked, a looping clip comes round to the head.
    @Test func aLoopWithNoRangeComesRoundToTheHead() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, presented) = try RawClipFixtures.player(frames: 8, in: root)
        defer { model.pause() }

        model.isLooping = true
        model.play()
        #expect(await ControllerWait.untilWritten { Self.restart(in: presented.all) != nil },
                "the loop never came round: \(presented.all)")
        #expect(Self.restart(in: presented.all) == 0)
    }

    /// The out point with looping OFF is where playback stops.
    @Test func theOutPointEndsPlaybackWhenNothingIsLooping() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, presented) = try RawClipFixtures.player(frames: 16, in: root)

        model.currentFrame = 5
        model.toggleRangePoint(out: true)
        model.currentFrame = 0
        model.play()
        #expect(await ControllerWait.untilWritten { !model.isPlaying })
        #expect(presented.all.allSatisfy { $0 <= 5 },
                "playback ran past the out point: \(presented.all)")
        #expect(model.playbackError == nil)
    }

    /// The first frame after the sequence went backwards — where a loop
    /// restarted — or nil while it has not.
    private static func restart(in shown: [Int]) -> Int? {
        zip(shown, shown.dropFirst()).first { $1 < $0 }?.1
    }
}
