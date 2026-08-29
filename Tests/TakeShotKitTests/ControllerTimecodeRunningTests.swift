import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// Whether the timecode is ADVANCING, which is a different question from
/// whether there is one.
///
/// A camera in standby on Rec Run holds its timecode still — the demo source is
/// exactly that by construction — and the slate page free-runs its own clock
/// from the last confirmed value. So a held timecode there is indistinguishable
/// from a page that has stopped working, which is what it looked like (owner:
/// "по хлопушке вообще не понял почему то бегает тк то останавливается"). The
/// app is the one that can tell, so it says.
@MainActor
struct ControllerTimecodeRunningTests {
    private func timecode(_ frames: Int) -> Timecode {
        Timecode(frameNumber: 25 * 60 * 60 * 10 + frames, fps: 25,
                 isDropFrame: false)
    }

    @Test func aHeldTimecodeIsReportedAsNotRunning() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.live.currentTimecode = timecode(0)
            // The FIRST status has nothing to compare against, and answers
            // "not running" rather than guessing: a page that opens mid-standby
            // must not be told the clock is moving until one has been seen to.
            #expect(!controller.remoteStatus().timecodeRunning)

            controller.live.currentTimecode = timecode(6)
            #expect(controller.remoteStatus().timecodeRunning,
                    "a timecode that advanced was reported as held")

            // …and the same value twice is a clock standing still
            #expect(!controller.remoteStatus().timecodeRunning,
                    "the same timecode twice was reported as running")
        }
    }

    /// No signal is not standby. With nothing on the wire there is no clock to
    /// call held, and the page says "no signal" on its own account.
    @Test func noTimecodeIsNotAHeldTimecode() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.live.currentTimecode = nil
            let status = controller.remoteStatus()
            #expect(status.timecode.isEmpty)
            #expect(!status.timecodeRunning)
        }
    }

    /// The flag reaches the page as JSON, which is the only way it can be read
    /// there — a value the encoder drops is a value the page defaults to false
    /// and never mentions again.
    @Test func theFlagIsOnTheWire() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.live.currentTimecode = timecode(0)
            _ = controller.remoteStatus()
            controller.live.currentTimecode = timecode(6)
            let json: String = controller.remoteStatus().json
            #expect(json.contains("\"tcRunning\":true"),
                    "a running clock does not reach the page: \(json)")
            let held: String = controller.remoteStatus().json
            #expect(held.contains("\"tcRunning\":false"),
                    "a held clock does not reach the page: \(held)")
        }
    }
}
