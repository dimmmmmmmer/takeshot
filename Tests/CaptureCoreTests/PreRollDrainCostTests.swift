import CoreMedia
import Foundation
import Testing

@testable import CaptureCore

/// **What the pre-roll drain costs the capture queue, measured rather than
/// argued about.**
///
/// `drainPreRoll` hands a whole window's worth of frames to the writer in one
/// burst, on the capture queue, waiting on each one inside a total budget. For
/// as long as that runs, nothing else on that queue does: live frames arrive
/// and fill the ingress window, and the ones past it are turned away at the
/// door — the frames just after the camera's REC press, which is what pre-roll
/// exists to keep.
///
/// The arithmetic below always runs and asserts. The timing is opt-in
/// (`TAKESHOT_BENCH=1 scripts/test.sh -c release --filter PreRollDrainCost`)
/// and asserts nothing about the clock: the number depends on the encoder, the
/// raster and the disk, and a threshold here would go red for reasons that
/// have nothing to do with this code. It prints what the budget is argued
/// from.
struct PreRollDrainCostTests {
    private static var benching: Bool {
        ProcessInfo.processInfo.environment["TAKESHOT_BENCH"] != nil
    }

    /// **The budget outlasts the window it is spent against.** Stated once,
    /// in the units an operator would ask in: at 25 fps a drain may hold the
    /// queue for 37 frames while ingress can hold 12, so a drain that spends
    /// its whole budget turns away the 25 that arrived behind it. Both halves
    /// are named constants precisely so this sentence can be checked.
    @Test func theDrainBudgetOutlastsTheIngressWindow() {
        #expect(CapturePipeline.drainBudgetSeconds == 1.5)
        #expect(CapturePipeline.ingressWindowFrames == 12)
        let framesInBudget = Int(CapturePipeline.drainBudgetSeconds * 25)
        #expect(framesInBudget == 37)
        #expect(framesInBudget > CapturePipeline.ingressWindowFrames,
                """
                a drain that spends its budget no longer outruns the window; \
                the finding this pins is gone and so is the reason for the \
                measurement below
                """)
    }

    /// What a drain actually spends, on this machine, for a full window.
    ///
    /// Deliberately not asserted. The interesting number is `budgetSpent`: at
    /// 1.0 the drain hit its deadline and the rest of the head of the take was
    /// dropped, which is the failure `preRollIncomplete` reports.
    @Test(.enabled(if: benching, "opt-in: TAKESHOT_BENCH=1"),
          arguments: [(1920, 1080, 25, "1080p25 proxy"),
                      (3840, 2160, 65, "UHD, a deep ring")])
    func whatAFullPreRollDrainSpends(
        width: Int, height: Int, ring: Int, name: String) async throws {
        let root = TestMedia.scratchDirectory("PreRollDrainCost")
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = TakeIntegrityBoundsTests.settings(root: root, preRoll: ring)
        let pipeline = CapturePipeline(config: .init(settings: settings,
                                                     takeNumber: 1))
        pipeline.handleFormat(CaptureFormat(width: width, height: height,
                                            frameRate: 25, timecodeFPS: 25,
                                            name: name))

        // a full window of standby, then the press
        let picture = TestMedia.pixelBuffer(width: width, height: height)
        for index in 1...(ring + 15) {
            pipeline.handleFrame(
                pixelBuffer: picture,
                pts: CMTime(value: CMTimeValue(index * 40), timescale: 1000),
                timecode: nil)
            try await Task.sleep(for: .milliseconds(5))
        }
        pipeline.toggleManualRecord()
        #expect(await TestWait.becomesTrue { pipeline.health.isRecording },
                "the take never opened")
        await pipeline.finishPendingWrites()
        pipeline.toggleManualRecord()
        await pipeline.finishPendingWrites()

        let cost = pipeline.lastDrainCost
        // A frame is 40 ms at 25 fps, so the drain's own duration in frames is
        // what a live feed has to hold while it runs — anything past the
        // ingress window is turned away at the door.
        let framesBehind = Int(cost.totalMs / 40)
        print("""
            pre-roll drain [\(name)]: \(String(format: "%.1f", cost.totalMs)) ms \
            (\(String(format: "%.0f", cost.budgetSpent * 100))% of the \
            \(CapturePipeline.drainBudgetSeconds) s budget), \
            \(cost.framesAppended) frames written, \
            \(cost.framesRefused) refused; \(framesBehind) live frames arrive \
            behind it against a \(CapturePipeline.ingressWindowFrames)-frame \
            window, so \(max(0, framesBehind - CapturePipeline.ingressWindowFrames)) \
            are dropped at ingress
            """)
        #expect(cost.totalMs > 0, "the drain reported nothing")
    }
}
