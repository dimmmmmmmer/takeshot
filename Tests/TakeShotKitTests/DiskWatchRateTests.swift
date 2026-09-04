import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// **The free-space close follows the write rate.** 0.5 GB was a fixed floor,
/// and at UHD ProRes it lasts less than one ten-second tick — so the writer hit
/// ENOSPC first, and the take died as a writer failure renamed `_FAILED` instead
/// of being closed while it could still finalize.
@Suite @MainActor struct DiskWatchRateTests {
    private let gb: Int64 = 1_000_000_000

    private func verdict(free: Int64, recording: Bool, rate: Double?)
        -> CaptureController.DiskVerdict {
        CaptureController.diskVerdict(freeBytes: free, isRecording: recording,
                                      bytesPerSecond: rate)
    }

    @Test func aFastWriterIsClosedWhileThereIsStillRoomToFinalize() {
        // 1 GB free, UHD ProRes 4444 at 50p: ~265 MB/s — under four seconds.
        let fast = verdict(free: 1 * gb, recording: true, rate: 265_000_000)
        if case .full = fast {} else {
            Issue.record("1 GB at 265 MB/s was left rolling: \(fast)")
        }
        // The same gigabyte at HD rates is not a close.
        let hd = verdict(free: 1 * gb, recording: true, rate: 20_000_000)
        if case .low = hd {} else { Issue.record("1 GB at 20 MB/s was closed: \(hd)") }
    }

    /// Without a measurement — the first tick of a take — the floor stands alone.
    @Test func noMeasurementKeepsTheFloor() {
        if case .low = verdict(free: 1 * gb, recording: true, rate: nil) {} else {
            Issue.record("1 GB with no rate was closed")
        }
        if case .full = verdict(free: gb / 4, recording: true, rate: nil) {} else {
            Issue.record("0.25 GB with no rate was left rolling")
        }
    }

    /// An idle app on a nearly full disk gets the warning, never an intervention.
    @Test func idleIsNeverClosed() {
        if case .full = verdict(free: gb / 4, recording: false, rate: 265_000_000) {
            Issue.record("closed a take that is not rolling")
        }
    }

    /// The tick is faster while a take rolls: two seconds against ten.
    @Test func theWatchTicksFasterWhileRecording() {
        #expect(CaptureController.diskWatchRecordingInterval < CaptureController.diskWatchIdleInterval)
        #expect(CaptureController.diskWatchRecordingInterval <= 2)
    }
}
