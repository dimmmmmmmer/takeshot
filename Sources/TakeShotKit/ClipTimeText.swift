import Foundation

/// A number of seconds as a clock, for every surface that shows one.
///
/// # Why this is one place and was three spellings
///
/// The app renders "so many seconds" as a clock in three places and each wrote
/// its own arithmetic:
///
/// | spelled in | width | rounding | non-finite |
/// | --- | --- | --- | --- |
/// | `TransportBar.timeText` — the sync-play transport, the marker list | `m:ss` | **down** | guarded, `0:00` |
/// | `durationText` — the takes panel's rows and tile badges, Other content | `m:ss` | **nearest** | **traps** |
/// | the shift report's and the contact sheet's header | `h:mm:ss` | down | **traps** |
///
/// Two of those columns are findings rather than choices.
///
/// **The rounding disagreed on screen.** The panel and the sync-play transport
/// show the same take's length at the same time — the grid's total is
/// `SyncPlaySchedule.length` and the row beside it is `durationSeconds` — and
/// for half of all lengths they printed different numbers. A 59.6 s take was
/// `1:00` in the panel and `0:59` on the transport under it, which counted up
/// to 0:59 and stopped. Down is the rule kept, because a transport's POSITION
/// has no choice: a clock that reads `1:00` while the picture is still inside
/// the 59th second is running ahead of the picture. Making the length agree
/// with the position it is the ceiling of is then the only consistent move.
///
/// Its cost is stated rather than hidden: a take under a second reads `0:00`.
/// That is what its length is to the nearest whole second, and the row's
/// timecode range beside it carries the frames.
///
/// **Only one of the three guarded a non-finite input, and `Int(_:)` traps on
/// one.** `Double.nan` and `Double.infinity` are not hypothetical here: both
/// take adoption (`CaptureController.embeddedMetadata`) and the Other-content
/// probe (`CaptureController.videoThumbnail`) read a length as
/// `(try? await asset.load(.duration))?.seconds`, and `CMTime.seconds` of an
/// indefinite or invalid time is NaN — which the `?? 0` next to it cannot
/// catch, because NaN is a Double and not a nil. `RemoteJSON.number` guards it
/// (the phone gets `null`) and `TransportBar.timeText` guarded it; the takes
/// panel's copy did not, and the takes panel is where such a file lands.
enum ClipTimeText {
    /// `0:00` … `100:07`. Minutes run past 60 rather than rolling into an hour
    /// column that is empty on every take of a normal day.
    case minutesSeconds
    /// `0:00:00` … `13:45:09`. The day's total on the two documents that leave
    /// set, where a run of hours is the ordinary case.
    case hoursMinutesSeconds

    /// The clock for `seconds`.
    ///
    /// Truncated, not rounded: see the type's note.
    ///
    /// Everything `Int(_:)` traps on is answered as zero instead, and the
    /// guard is as wide as the trap. `isFinite` alone is NOT: `Int(_:)` also
    /// refuses anything that rounds past `Int.max`, and that is finite — so
    /// the value is clamped as well, to `Int.max / 2`, which is exactly
    /// representable as a Double and leaves a whole binary order of magnitude
    /// of headroom. A length read off a damaged file is not promised to be
    /// small. A negative answers zero for a third reason: `%02d` of a negative
    /// remainder printed `0:-1`, a clock with a minus sign inside it.
    func text(_ seconds: Double) -> String {
        let bounded = seconds.isFinite
            ? min(Double(Int.max / 2), max(0, seconds)) : 0
        let total = Int(bounded.rounded(.down))
        switch self {
        case .minutesSeconds:
            return String(format: "%d:%02d", total / 60, total % 60)
        case .hoursMinutesSeconds:
            return String(format: "%d:%02d:%02d",
                          total / 3600, (total / 60) % 60, total % 60)
        }
    }
}
