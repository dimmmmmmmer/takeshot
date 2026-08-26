import Foundation
import os

/// **One 90 kHz origin for every live encoder there is.**
///
/// A `LiveVideoEncoder` stamps each frame at `(now − origin) × 90000`, and while
/// there was one session that origin could be its own first frame. There is a
/// session per DISTINCT picture now, and a browser is allowed to change which
/// one it is watching without the connection being torn down — so two sessions
/// have to number the same instant the same way.
///
/// **What a private origin per session would cost, exactly.** The second
/// encoder is built the moment somebody first asks for its picture, which on a
/// shooting day is minutes after the first: its stamps start near zero while
/// the first is hundreds of seconds in. A viewer moved from the first to the
/// second would hand its browser an RTP timestamp several minutes in the past
/// on a stream that has not stopped, and a jitter buffer answers that by
/// holding the picture until its own clock catches up — a stall with no error
/// anywhere, for a button the operator just pressed. Sharing the origin makes
/// the gap at a switch what it actually is: one frame interval.
///
/// The monotonic forcing stays per encoder (`LiveVideoEncoder.nextTicks`).
/// That is about one session's own stamps never repeating, and two sessions
/// pushing each other's forward would be a different bug.
final class LiveClock: @unchecked Sendable {
    /// Whoever stamps first sets it, and it never moves again while the app
    /// runs. A lock rather than a queue: this is read on each encoder's own
    /// queue, which is a different queue per picture, and the read is a
    /// compare and a store.
    private let stored = OSAllocatedUnfairLock<TimeInterval?>(initialState: nil)

    /// The shared origin, adopting `now` as it if nothing has stamped yet.
    func origin(at now: TimeInterval) -> TimeInterval {
        stored.withLock { value in
            if let value { return value }
            value = now
            return now
        }
    }

    /// Whether anything has stamped against this clock yet. For the tests: an
    /// origin that was shared and one that only looks like it was are
    /// indistinguishable from outside otherwise.
    var hasStarted: Bool { stored.withLock { $0 != nil } }
}
