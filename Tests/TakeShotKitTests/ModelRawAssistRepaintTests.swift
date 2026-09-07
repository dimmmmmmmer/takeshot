import CaptureCore
import CoreVideo
import Foundation
import Testing

@testable import TakeShotKit

/// **A paused RAW clip redraws its aids off the main thread.**
///
/// The aids are drawn INTO the presented frame — that is what reaches the
/// hardware playout — so changing them on a paused clip means rendering the
/// frame again. That was `present(lastBuffer)` inline on the MainActor: a whole
/// CoreImage pass, affordable once when a checkbox is ticked and not at all
/// affordable at a slider's rate. The draft path calls it about sixty times a
/// second for as long as a zebra threshold or a punch-in is being dragged, and
/// a paused RAW clip made the window stutter under that drag — the same
/// complaint the compare wipe had.
@Suite @MainActor struct ModelRawAssistRepaintTests {
    /// Which thread each presented frame was drawn on, and how many there were.
    private final class Draws: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Bool] = []

        func record(onMain: Bool) { lock.withLock { stored.append(onMain) } }
        var count: Int { lock.withLock { stored.count } }
        var anyOnMain: Bool { lock.withLock { stored.contains(true) } }
    }

    private func paused(in root: URL) async throws
        -> (model: RawPlayerModel, draws: Draws) {
        let (model, _) = try RawClipFixtures.player(frames: 8, in: root)
        let draws = Draws()
        model.setOnDisplayFrame { _ in draws.record(onMain: Thread.isMainThread) }
        model.seek(to: 2)
        #expect(await ControllerWait.untilWritten { model.lastBuffer != nil },
                "no frame reached the model, so there is nothing to redraw")
        return (model, draws)
    }

    @Test func changingTheAidsOnAPausedClipDoesNotRenderOnMain() async throws {
        let root = MediaFixtures.scratchDirectory("RawAssistRepaint")
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, draws) = try await paused(in: root)
        let seeded = draws.count

        var assist = ViewAssist()
        assist.zebraOn = true
        assist.zebraThreshold = 0.8
        model.setViewAssist(assist)

        #expect(await ControllerWait.untilWritten { draws.count > seeded },
                "the aids never reached the picture")
        #expect(!draws.anyOnMain,
                "a frame was rendered on the main thread")
    }

    /// And a DRAG coalesces. Sixty changes must not be sixty renders: the
    /// request that arrives mid-pass is remembered, not queued behind it, so
    /// what lands is the value the operator settled on.
    @Test func aDragCoalescesIntoFewerRendersThanItAsksFor() async throws {
        let root = MediaFixtures.scratchDirectory("RawAssistDrag")
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, draws) = try await paused(in: root)
        let seeded = draws.count

        for step in 0..<60 {
            var assist = ViewAssist()
            assist.zebraOn = true
            assist.zebraThreshold = Double(50 + step) / 100
            model.setViewAssist(assist)
        }
        #expect(await ControllerWait.untilWritten { draws.count > seeded },
                "a drag drew nothing at all")
        // Settle, so a pass still in flight is counted.
        try await Task.sleep(for: .milliseconds(400))
        let drawn = draws.count - seeded
        // **Eight, not sixty.** `< 60` passes against fifty-nine renders, which
        // is no coalescing at all — the bound was the number of TICKS and so
        // could never fail for the thing it was written about. Measured here:
        // two. Eight is the loosest number that still says "coalesced" and
        // leaves a loaded runner room for a few passes in flight.
        #expect(drawn <= 8, "sixty slider ticks cost \(drawn) full renders")
        #expect(!draws.anyOnMain, "a frame was rendered on the main thread")
    }

    /// **Two presents never overlap, whichever four callers race.**
    ///
    /// The play loop, a seek's detached decode, the paused repaint and a layer
    /// mounting itself on the main actor all reach `present`. Two of them
    /// racing put the OLDER frame on the surface last: a seek that visibly
    /// does not take, once in twenty tries and never in front of anyone who
    /// could help. `AssistStage` was already safe — it takes a render lock and
    /// names this player as the reason it has one — so what was missing was
    /// ORDER, and order is a serial queue.
    @Test func twoPresentsNeverOverlap() async throws {
        let root = MediaFixtures.scratchDirectory("RawPresentOverlap")
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, _) = try RawClipFixtures.player(frames: 4, in: root)
        let overlap = Overlap()
        model.seek(to: 1)
        #expect(await ControllerWait.untilWritten { model.lastBuffer != nil },
                "no frame reached the model")
        let buffer = try #require(model.lastBuffer)
        model.setOnDisplayFrame { _ in overlap.enter() }

        // Eight presents from eight threads at once, which is more than a real
        // run ever has and is the point: one overlap is enough to fail.
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            model.present(buffer)
        }
        model.settlePresents()
        #expect(overlap.peak == 1, "\(overlap.peak) presents ran at once")
        #expect(overlap.total >= 8,
                "only \(overlap.total) of the presents landed")
    }
}

/// How many presents were inside the handler at once.
private final class Overlap: @unchecked Sendable {
    private let lock = NSLock()
    private var inside = 0
    private var highest = 0
    private var count = 0

    func enter() {
        lock.withLock {
            inside += 1
            count += 1
            highest = max(highest, inside)
        }
        // Long enough that an overlapping caller is certain to be seen, and
        // short enough that eight of them cost a fifth of a second.
        Thread.sleep(forTimeInterval: 0.02)
        lock.withLock { inside -= 1 }
    }

    var peak: Int { lock.withLock { highest } }
    var total: Int { lock.withLock { count } }
}
