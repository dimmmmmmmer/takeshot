import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// The RAW engine's scope path — the odd one out, and the reason it needs a
/// suite of its own.
///
/// The capture pipeline and the playback tap both hand a frame to a queue that
/// analyses at a wall-clock rate. A RAW clip is decoded a frame per task and
/// spends most of a review PAUSED, so the cadence is counted in decoded frames
/// and a paused clip is re-analysed on demand. Neither half had ever run: with
/// no fixture that decodes there was no frame to analyse.
@Suite @MainActor struct ModelRawScopeTests {
    /// A clip with a frame on screen and the scopes open, plus everything the
    /// analyser sends back.
    ///
    /// The scopes are opened AFTER the seek has landed, so the count these
    /// tests read is theirs alone — and the wait is on `lastBuffer` rather than
    /// on a presented frame, because that is what `refreshScopes` reads: the
    /// engine hands the picture to the surfaces first and files it a hop later,
    /// so a test that waited for the picture could ask for an analysis of a
    /// frame the model had not filed yet and be answered with silence.
    private func paused(frames: Int = 8, in root: URL) async throws
        -> (model: RawPlayerModel, passes: Passes) {
        let (model, _) = try RawClipFixtures.player(frames: frames, in: root)
        let passes = Passes()
        model.onScopeData = { _ in passes.record() }
        model.seek(to: 2)
        #expect(await ControllerWait.untilWritten { model.lastBuffer != nil },
                "no frame reached the model, so there is nothing to analyse")
        model.scopesEnabled = true
        return (model, passes)
    }

    /// Scope passes, counted. They land on the main actor while the test polls
    /// from a concurrency worker, so the count goes behind a lock.
    private final class Passes: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        var count: Int { lock.withLock { value } }
        func record() { lock.withLock { value += 1 } }
    }

    /// A rate target rather than a fixed count: the analysis rides on the
    /// decode task itself, so a 24 fps clip and a 60 fps one must cost the
    /// decoder the same share of its frames rather than the same number.
    @Test func theStrideFollowsTheClipsOwnFrameRate() async throws {
        let root = try MediaFixtures.makeDirectory("raw-scope-stride")
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, _) = try RawClipFixtures.player(frames: 4, in: root)

        // a folder of plain frames carries no CinemaDNG rate tag, so the
        // engine's 24 fps fallback is what this clip runs at
        #expect(model.frameRate == 24)
        #expect(model.scopeFrameStride
                == RawPlayerModel.scopeFrameStride(atFrameRate: 24))
        #expect(model.scopeFrameStride == 3)
        #expect(RawPlayerModel.scopeFrameStride(atFrameRate: 60) == 8)
        // and never zero, whatever a clip claims about itself
        #expect(RawPlayerModel.scopeFrameStride(atFrameRate: 0) == 1)
    }

    /// A paused clip decodes nothing new, so the scopes have to be re-run on
    /// demand — a surface that just opened, or a punch-in crop that just moved,
    /// would otherwise keep showing the previous crop until playback resumed.
    @Test func aPausedClipIsReAnalysedOnDemand() async throws {
        let root = try MediaFixtures.makeDirectory("raw-scope-refresh")
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, passes) = try await paused(in: root)

        model.refreshScopes()
        #expect(await ControllerWait.untilWritten { passes.count == 1 },
                "the paused clip was never re-analysed")
    }

    /// Latest-wins, with the last request REMEMBERED rather than dropped. A pan
    /// drag asks sixty times a second and every pass is a whole frame of
    /// analysis; dropping the ones that arrive mid-pass would leave the scopes
    /// showing a crop the operator has already moved away from, for ever —
    /// nothing else comes along on a paused clip to correct it.
    ///
    /// Exactly two passes, and that is arithmetic rather than a range: the
    /// twenty calls run without a suspension between them, so the first starts
    /// a pass and the other nineteen collapse into the one flag it reads on the
    /// way out.
    @Test func requestsDuringAPassCollapseToOneMore() async throws {
        let root = try MediaFixtures.makeDirectory("raw-scope-coalesce")
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, passes) = try await paused(in: root)

        for _ in 0..<20 { model.refreshScopes() }
        #expect(await ControllerWait.untilWritten { passes.count >= 2 })
        // full budget on purpose: this waits for passes that must NOT happen
        _ = await ControllerWait.until({ passes.count > 2 },
                                       timeout: .milliseconds(500))
        #expect(passes.count == 2,
                "twenty drag events cost \(passes.count) analyses")
    }

    /// With the scopes closed there is no analysis at all. Every paused seek
    /// and every poster frame used to run a full pass and throw it away.
    @Test func closedScopesCostNothing() async throws {
        let root = try MediaFixtures.makeDirectory("raw-scope-off")
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, passes) = try await paused(in: root)

        model.scopesEnabled = false
        model.refreshScopes()
        model.seek(to: 5)
        _ = await ControllerWait.until({ passes.count > 0 },
                                       timeout: .milliseconds(500))
        #expect(passes.count == 0, "a closed scope panel was still analysing")
    }

    /// While the clip runs, the scopes are fed from the decode task at the
    /// stride — not every frame. Analysing each one is a frame the decoder does
    /// not get to work on, which shows up as a review that will not hold rate.
    @Test func playbackFeedsTheScopesAtTheStrideAndNotEveryFrame() async throws {
        let root = try MediaFixtures.makeDirectory("raw-scope-play")
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, presented) = try RawClipFixtures.player(frames: 24, in: root)
        let passes = Passes()
        model.onScopeData = { _ in passes.record() }
        model.scopesEnabled = true

        model.play()
        #expect(await ControllerWait.untilWritten { !model.isPlaying })
        // Exact rather than a range: the counter runs over the frames that
        // reached the screen, so one pass every `stride` of them is arithmetic.
        // A loaded machine drops frames and shows fewer — which changes both
        // sides of this and not the claim.
        let shown = presented.count
        let stride = model.scopeFrameStride
        #expect(passes.count == shown / stride,
                "\(passes.count) analyses for \(shown) frames at stride \(stride)")
    }
}
