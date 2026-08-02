import CaptureCore
import Foundation

/// How the takes of a sync-play session line up on the master timeline.
enum SyncPlayAlignmentMode: String, CaseIterable {
    /// Every clip at its own first frame — action starts are compared take by
    /// take, whatever the camera's clock was doing.
    case byStart
    /// Clips aligned on their shared timecode overlap — the same scene shot
    /// several times has near-identical TC ranges, so the same wall-clock
    /// moment lands in every tile at once.
    case byTimecode
}

/// Where each clip sits on the master timeline, and how long that timeline is.
///
/// Pure arithmetic, separate from the players it drives: the offsets decide
/// what every seek and every synchronized start does, so they are computed in
/// one place the tests can interrogate without media.
struct SyncPlaySchedule: Equatable {
    /// Seconds INTO each clip at master time 0. A clip's own position for a
    /// master time `t` is `offsets[i] + t`, clamped to the clip's duration —
    /// the clamp is the freeze-on-last-frame rule.
    var offsets: [Double]
    /// Master timeline length, seconds.
    var length: Double
    /// Timecode alignment was actually applied. False under `.byStart`, and
    /// false when `.byTimecode` had to fall back — a missing TC or ranges that
    /// never overlap — which is what the grid's fallback note reads.
    var usedTimecode: Bool

    /// All clips at their own 0; the transport runs to the end of the longest
    /// one while shorter clips freeze on their last frame.
    static func byStart(durations: [Double]) -> SyncPlaySchedule {
        SyncPlaySchedule(offsets: durations.map { _ in 0 },
                         length: durations.max() ?? 0,
                         usedTimecode: false)
    }

    /// Clips aligned on their shared TC overlap.
    ///
    /// Each clip covers `[start, start + duration]` in seconds since midnight
    /// (`Timecode.frameNumber` over its rate, so drop-frame and mixed rates
    /// land in one common domain). The master timeline is CLAMPED to the
    /// intersection of all ranges — the honest comparison window: every master
    /// second exists in every take, so nothing on screen is ever a frozen
    /// stand-in for footage another tile actually has. Takes without a TC, or
    /// with no common overlap, fall back to `byStart` (flagged via
    /// `usedTimecode` so the UI can say so).
    static func byTimecode(startTimecodes: [Timecode?],
                           durations: [Double]) -> SyncPlaySchedule {
        var starts: [Double] = []
        for timecode in startTimecodes {
            guard let timecode else {
                return byStart(durations: durations)
            }
            starts.append(Double(timecode.frameNumber)
                / Double(max(1, timecode.fps)))
        }
        guard let windowStart = starts.max(),
              let windowEnd = zip(starts, durations).map(+).min(),
              windowEnd - windowStart > 0 else {
            return byStart(durations: durations)
        }
        return SyncPlaySchedule(offsets: starts.map { windowStart - $0 },
                                length: windowEnd - windowStart,
                                usedTimecode: true)
    }

    /// The schedule for a mode, from the facts every take carries.
    static func compute(_ mode: SyncPlayAlignmentMode,
                        startTimecodes: [Timecode?],
                        durations: [Double]) -> SyncPlaySchedule {
        switch mode {
        case .byStart:
            return byStart(durations: durations)
        case .byTimecode:
            return byTimecode(startTimecodes: startTimecodes,
                              durations: durations)
        }
    }
}
