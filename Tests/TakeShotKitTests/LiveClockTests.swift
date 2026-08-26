import CoreMedia
import Foundation
import Testing

@testable import TakeShotKit

/// **One clock for every live session**, and why the alternative is a stall.
///
/// With a session per picture, a viewer is allowed to move from one to the
/// other on the connection it already has. Each session used to zero its 90 kHz
/// clock on its own first frame — so a session built minutes later stamped the
/// same instant minutes lower, and moving a viewer onto it would hand the
/// browser an RTP timestamp far in the past on a stream that never stopped.
/// A jitter buffer answers that by holding the picture until its own clock
/// catches up: no error anywhere, and a black rectangle for a button somebody
/// just pressed.
struct LiveClockTests {
    /// Whoever stamps first sets it, and it never moves again.
    @Test func theOriginIsAdoptedOnceAndSharedAfterwards() {
        let clock = LiveClock()
        #expect(!clock.hasStarted)
        #expect(clock.origin(at: 1000) == 1000)
        #expect(clock.hasStarted)
        // A second session, minutes later, gets the FIRST one's zero.
        #expect(clock.origin(at: 1300) == 1000)
        #expect(clock.origin(at: 900) == 1000,
                "a later reader moved the origin backwards")
    }

    /// Two encoders on one clock number the same instant the same way.
    ///
    /// The number this pins is the SIZE of the jump a picture change costs, and
    /// it is stated in the units the wire uses: at 90 kHz, five minutes is
    /// 27 million ticks. Sharing the origin makes the gap the frame interval it
    /// actually is.
    @Test func twoSessionsBuiltApartStampTheSameInstantTheSame() {
        let clock = LiveClock()
        let first = LiveVideoEncoder(bitsPerSecond: 1_000_000, clock: clock)
        let second = LiveVideoEncoder(bitsPerSecond: 1_000_000, clock: clock)
        // The first session starts the clock; the second joins five minutes in.
        let start: TimeInterval = clock.origin(at: 100)
        let later: TimeInterval = start + 300
        #expect(first.ticks(at: later) == second.ticks(at: later),
                "\(first.ticks(at: later)) against \(second.ticks(at: later))")
        // And the number is the elapsed time on the transport stream's clock,
        // not an offset from whenever each session happened to be built.
        #expect(second.ticks(at: later + 0.04)
                    - second.ticks(at: later) == 3600,
                "a 40 ms step is not one frame at 90 kHz")
    }

    /// A private clock per session is what this replaced, and the size of the
    /// error it removes is worth stating rather than describing.
    @Test func aPrivateClockWouldPutTheSecondSessionMinutesBehind() {
        let first = LiveVideoEncoder(bitsPerSecond: 1_000_000,
                                     clock: LiveClock())
        let second = LiveVideoEncoder(bitsPerSecond: 1_000_000,
                                      clock: LiveClock())
        _ = first.ticks(at: 100) // the first session starts here
        let later: TimeInterval = 400 // five minutes of shooting
        _ = second.ticks(at: later) // …and the second one here
        let gap: Int64 = first.ticks(at: later + 1) - second.ticks(at: later + 1)
        #expect(gap > 26_000_000,
                "the two clocks were closer than five minutes: \(gap)")
    }
}
