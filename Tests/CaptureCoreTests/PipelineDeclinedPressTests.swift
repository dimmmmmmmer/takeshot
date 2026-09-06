import Foundation
import Testing

@testable import CaptureCore

/// **A REC press that opened nothing says why.**
///
/// `beginTake` declines when no format has locked — a re-seated cable, a
/// camera mid power-cycle. The multicam fix made the decline report its STATE
/// so a relay's latch cleared; the operator-facing half stayed silent, and on
/// a remote press there is not even a button to watch.
struct PipelineDeclinedPressTests {
    @Test func aPressWithNoSignalLockedIsSaidToTheOperator() async {
        let pipeline = CapturePipeline(
            config: .init(settings: CaptureSettings(), takeNumber: 1))
        let errors = EventCollector<PipelineAlarm>()
        pipeline.onError = { errors.append($0) }

        pipeline.toggleManualRecord()

        #expect(await TestWait.becomesTrue {
            errors.all.contains(.recordingRefusedNoSignal)
        }, "the refused press went unmentioned: \(errors.all)")
        // no footage was lost: the size of it is a toast, not the register
        #expect(PipelineAlarm.recordingRefusedNoSignal.severity == .notice)
    }

    /// The relay's door reports the STATE and not the reason: it fires on
    /// every A-cam take, and a B-cam without a signal would toast on each of
    /// them while its own tile already says so.
    @Test func aRelayedPressWithNoSignalReportsOnlyTheState() async throws {
        let pipeline = CapturePipeline(
            config: .init(settings: CaptureSettings(), takeNumber: 1))
        let errors = EventCollector<PipelineAlarm>()
        let recStates = EventCollector<Bool>()
        pipeline.onError = { errors.append($0) }
        pipeline.onRecStateChanged = { recStates.append($0) }

        pipeline.setManualRecord(true)

        #expect(await TestWait.becomesTrue { recStates.last == false },
                "the relay's latch was never cleared")
        try await Task.sleep(for: .milliseconds(150))
        #expect(!errors.all.contains(.recordingRefusedNoSignal),
                "a relayed start toasted for a channel whose tile already says no signal")
    }
}
