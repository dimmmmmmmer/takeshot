import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// The clock the app puts on a number of seconds — the takes panel's rows and
/// tile badges, the Other-content rows, the sync-play transport, the marker
/// list, and the day's total on the two documents that leave set.
///
/// Three spellings before `ClipTimeText`, differing in the two ways that
/// matter: which direction they rounded, and whether they survived a length
/// that is not a number.
@Suite struct ModelClipTimeTextTests {
    // MARK: - the rounding, and why it is down

    /// The finding. The panel and the sync-play transport show the same take's
    /// length at the same time — the row and the grid total — and used to
    /// disagree on every length whose fractional part is a half second or
    /// more, because one rounded to nearest and the other truncated.
    @Test func aLengthReadsAsTheWholeSecondsTheTransportCanCountTo() {
        let readings: [(seconds: Double, text: String)] = [
            (0.0, "0:00"),
            (0.9, "0:00"),
            (1.0, "0:01"),
            (12.0, "0:12"),
            // the case the two surfaces disagreed on: nearest said "1:00"
            // over a transport that counts to 0:59 and stops
            (59.6, "0:59"),
            (59.999, "0:59"),
            (60.0, "1:00"),
            // minutes run past 60 rather than into an empty hour column
            (6007.0, "100:07"),
        ]
        for reading in readings {
            let text: String = ClipTimeText.minutesSeconds.text(reading.seconds)
            #expect(text == reading.text,
                    "\(reading.seconds)s read as \(text), not \(reading.text)")
        }
    }

    /// The day's total, which is the only place an hours column is worth its
    /// width. Same truncation, one column wider.
    @Test func theDaysTotalCarriesAnHoursColumn() {
        let readings: [(seconds: Double, text: String)] = [
            (0.0, "0:00:00"),
            (59.6, "0:00:59"),
            (3661.9, "1:01:01"),
            (49_509.0, "13:45:09"), // 13 h 45 m 09 s
            // past a day it keeps counting rather than wrapping: a total is a
            // quantity, not a time of day
            (90_000.0, "25:00:00"),
        ]
        for reading in readings {
            let text: String = ClipTimeText.hoursMinutesSeconds
                .text(reading.seconds)
            #expect(text == reading.text,
                    "\(reading.seconds)s read as \(text), not \(reading.text)")
        }
    }

    // MARK: - what `Int(_:)` traps on

    /// The other finding, and the one that is not cosmetic. Both lengths the
    /// panel shows are read as `(try? await asset.load(.duration))?.seconds`,
    /// and `CMTime.seconds` of an indefinite or invalid time is NaN — which
    /// the `?? 0` beside it cannot catch, because NaN is a Double and not a
    /// nil. `Int(Double.nan)` traps, so the old panel spelling would have
    /// taken the app down on one unreadable file in the record folder.
    @Test func aLengthThatIsNotANumberReadsAsZeroInsteadOfTrapping() {
        let notANumber: [Double] = [.nan, .signalingNaN, .infinity, -.infinity]
        for value in notANumber {
            #expect(ClipTimeText.minutesSeconds.text(value) == "0:00",
                    "\(value) did not read as 0:00")
            #expect(ClipTimeText.hoursMinutesSeconds.text(value) == "0:00:00",
                    "\(value) did not read as 0:00:00")
        }
    }

    /// A negative used to print a minus sign INSIDE the clock — `%02d` of a
    /// negative remainder — rather than being refused. `0:-1` is not a time.
    @Test func aNegativeLengthDoesNotPrintAMinusInsideTheClock() {
        for value in [-0.5, -1.0, -61.0, -3661.0] {
            #expect(ClipTimeText.minutesSeconds.text(value) == "0:00")
            #expect(ClipTimeText.hoursMinutesSeconds.text(value) == "0:00:00")
        }
    }

    /// The clamp is wider than the `isFinite` guard on purpose: `Int(_:)`
    /// refuses everything past `Int.max` too, and that is FINITE, so a guard
    /// on `isFinite` alone still traps. Nothing sensible can be printed for a
    /// length of 10^308 seconds — what is pinned is that the panel survives
    /// being handed one.
    @Test func aFiniteLengthTooLargeForAnIntDoesNotTrapEither() {
        let huge: [Double] = [Double(Int.max), Double(Int.max) * 2,
                              Double.greatestFiniteMagnitude]
        for value in huge {
            #expect(!ClipTimeText.minutesSeconds.text(value).isEmpty)
            #expect(!ClipTimeText.hoursMinutesSeconds.text(value).isEmpty)
        }
    }
}
