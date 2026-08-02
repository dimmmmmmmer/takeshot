import Foundation
import Testing

@testable import CaptureCore

/// The dailies queue's contract, over real media (`DailiesRig`): FIFO with a
/// failed item marked and skipped, Stop that deletes the partial file and
/// cancels the rest, Skip that costs exactly one item, and the pause gate
/// the recording-protection rule stands on. Everything polls outcomes with
/// I/O-sized budgets; nothing waits on the wall clock.
struct DailiesQueueTests {
    @Test func theQueueRunsFIFOAndAFailedItemIsSkippedNotFatal() async throws {
        let root = try DailiesRig.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let good1 = try await DailiesRig.writeTake(
            at: root.appendingPathComponent("a.mov"), frames: 8)
        // named like a movie, is not one — the failure the queue must survive
        let corrupt = root.appendingPathComponent("b.mov")
        try Data(repeating: 0x5A, count: 4096).write(to: corrupt)
        let good2 = try await DailiesRig.writeTake(
            at: root.appendingPathComponent("c.mov"), frames: 8)

        let log = DailiesProgressLog()
        let report = await DailiesEngine.run(
            items: [good1, corrupt, good2].map { DailiesRig.item(for: $0) },
            burnins: DailiesRig.noBurnins,
            into: root.appendingPathComponent("Dailies")) { log.record($0) }

        #expect(report.items.count == 3)
        #expect(report.items[0].output != nil)
        #expect(report.items[1].failure != nil)
        #expect(report.items[1].output == nil)
        #expect(report.items[2].output != nil, "the failure blocked the queue")
        #expect(!report.wasCancelled)
        for result in [report.items[0], report.items[2]] {
            let output = try #require(result.output)
            #expect(FileManager.default.fileExists(atPath: output.path))
        }
        // FIFO: the item index never goes backwards
        let order = log.all.map(\.itemIndex)
        #expect(order == order.sorted())
    }

    /// Hold the queue mid-item so a cancel/skip test has a deterministic
    /// moment to press its button in: the trip-wire pauses the run once real
    /// frames have moved, and the caller acts on the frozen queue. Returns
    /// the run task and the log; the caller resumes via `control`.
    private func runHeldMidItem(items: [DailiesItem], into folder: URL,
                                control: DailiesControl) async
        -> (run: Task<DailiesReport, Never>, log: DailiesProgressLog) {
        let log = DailiesProgressLog(
            tripWire: { $0.itemIndex == 0 && $0.framesDone > 5 },
            onTrip: { control.setPaused(true) })
        let run = Task {
            await DailiesEngine.run(items: items,
                                    burnins: DailiesRig.noBurnins,
                                    into: folder,
                                    control: control) { log.record($0) }
        }
        // Poll the outcome: the engine says it is holding, frames already in.
        var budget = 600 // 30 s of 50 ms steps — an I/O-sized budget
        while !log.all.contains(where: { $0.isPaused && $0.framesDone > 5 }),
              budget > 0 {
            budget -= 1
            try? await Task.sleep(for: .milliseconds(50))
        }
        return (run, log)
    }

    @Test func cancelMidItemDeletesThePartialFileAndCancelsTheRest() async throws {
        let root = try DailiesRig.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        // long enough that the throttled progress reports it mid-run
        let first = try await DailiesRig.writeTake(
            at: root.appendingPathComponent("a.mov"), frames: 1000)
        let second = try await DailiesRig.writeTake(
            at: root.appendingPathComponent("b.mov"), frames: 25)
        let folder = root.appendingPathComponent("Dailies")

        let control = DailiesControl()
        let (run, log) = await runHeldMidItem(
            items: [DailiesRig.item(for: first), DailiesRig.item(for: second)],
            into: folder, control: control)
        #expect(log.all.contains { $0.isPaused && $0.framesDone > 5 },
                "the run never reported holding mid-item")
        // Stop pressed on the held queue — deterministically mid-item, with
        // real frames already through the encoder.
        control.cancel()
        control.setPaused(false)
        let report = await run.value

        #expect(report.wasCancelled)
        #expect(report.items.count == 2)
        #expect(report.items[0].wasCancelled)
        #expect(report.items[1].wasCancelled, "cancel must stop the queue too")
        // nothing half-written stays behind
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil)) ?? []
        #expect(leftovers.filter { $0.pathExtension == "mp4" }.isEmpty,
                "partial dailies left behind: \(leftovers)")
    }

    @Test func skipCancelsTheCurrentItemAndTheNextOneStillRuns() async throws {
        let root = try DailiesRig.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await DailiesRig.writeTake(
            at: root.appendingPathComponent("a.mov"), frames: 1000)
        let second = try await DailiesRig.writeTake(
            at: root.appendingPathComponent("b.mov"), frames: 8)

        let control = DailiesControl()
        let (run, log) = await runHeldMidItem(
            items: [DailiesRig.item(for: first), DailiesRig.item(for: second)],
            into: root.appendingPathComponent("Dailies"), control: control)
        #expect(log.all.contains { $0.isPaused && $0.framesDone > 5 },
                "the run never reported holding mid-item")
        control.skip(item: 0)
        control.setPaused(false)
        let report = await run.value

        #expect(report.items[0].wasCancelled)
        #expect(report.items[0].output == nil)
        #expect(report.items[1].output != nil, "skip must only cost one item")
        // a skip is not a cancelled run — every other daily exists
        #expect(!report.wasCancelled)
    }

    /// The recording-protection gate at engine level: a paused control holds
    /// the queue before the first frame, and releasing it lets the run
    /// finish. (That the REC state actually drives this gate is the
    /// controller suite's test.)
    @Test func thePauseGateHoldsFramesAndReleaseResumes() async throws {
        let root = try DailiesRig.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await DailiesRig.writeTake(
            at: root.appendingPathComponent("a.mov"), frames: 25)

        let control = DailiesControl()
        control.setPaused(true)
        let log = DailiesProgressLog()
        let fixture = DailiesRig.item(for: source)
        let folder = root.appendingPathComponent("Dailies")
        let run = Task {
            await DailiesEngine.run(items: [fixture],
                                    burnins: DailiesRig.noBurnins,
                                    into: folder,
                                    control: control) { log.record($0) }
        }
        // Poll the outcome: the engine says it is paused, with zero frames
        // through the encoder.
        var budget = 600 // 30 s of 50 ms steps — an I/O-sized budget
        while !log.all.contains(where: { $0.isPaused }), budget > 0 {
            budget -= 1
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(log.all.contains { $0.isPaused }, "the gate never engaged")
        #expect(log.all.allSatisfy { $0.framesDone == 0 },
                "frames moved while paused")

        control.setPaused(false)
        let report = await run.value
        let output = try #require(report.items.first?.output)
        #expect(FileManager.default.fileExists(atPath: output.path))
        #expect(report.isFullySucceeded)
    }
}
