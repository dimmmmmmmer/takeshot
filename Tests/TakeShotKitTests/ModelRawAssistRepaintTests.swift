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
        #expect(drawn < 60, "sixty slider ticks cost \(drawn) full renders")
        #expect(!draws.anyOnMain, "a frame was rendered on the main thread")
    }
}
