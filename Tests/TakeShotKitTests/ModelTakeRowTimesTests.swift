import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// The two numbers under a take's name in the takes panel.
///
/// This is the readout the operator quotes over talkback while the production
/// office reads the shift report, so what it has to be is not "reasonable" but
/// "the same string the paperwork carries". `TakeSpanTests` pins the arithmetic
/// in CaptureCore; this pins that the ROW is built out of it and not out of a
/// second copy — which is exactly how the panel came to be a frame per thousand
/// ahead of every document about the same take.
@Suite struct ModelTakeRowTimesTests {
    private func take(tc: Timecode?, duration: Double) -> Take {
        Take(url: URL(fileURLWithPath: "/tmp/A001C001.mov"),
             scene: "", roll: "A001", takeNumber: 1,
             startTimecode: tc, durationSeconds: duration,
             recordedAt: Date(timeIntervalSince1970: 0))
    }

    /// The acceptance case, on the rate family where the old arithmetic was
    /// wrong. Ten minutes at 29.97 drop-frame: the row used to end the take on
    /// `10:10:00;18` while the report, the ALE and the EDL all said
    /// `10:10:00;00`.
    @Test func theRowsRangeIsTheOneTheShiftReportPrints() throws {
        let subject = take(
            tc: Timecode(hours: 10, minutes: 0, seconds: 0, frames: 0, fps: 30,
                         isDropFrame: true),
            duration: 600)
        let range: String = try #require(
            TakeRowTimes.timecodeRange(of: subject))
        let paperEnd = try #require(TakeLogExporter.endTimecode(of: subject))
        #expect(range == "10:00:00;00 – \(paperEnd.description)")
        #expect(range == "10:00:00;00 – 10:10:00;00")
        // the number it must not be, verbatim from the old row
        #expect(!range.contains("10:10:00;18"))
    }

    /// A non-drop take, where the two arithmetics agree — so the row is
    /// unchanged for every 24/25/50 fps day, which is most of them.
    @Test func aNonDropRowIsUnchanged() throws {
        let subject = take(
            tc: Timecode(hours: 10, minutes: 0, seconds: 0, frames: 0, fps: 25),
            duration: 12)
        #expect(try #require(TakeRowTimes.timecodeRange(of: subject))
            == "10:00:00:00 – 10:00:12:00")
    }

    /// No timecode, no range. The row already carries the LENGTH beside this,
    /// so nothing is lost — where `00:00:00:00 – 00:00:12:00` on a row between
    /// nine real timecodes reads as a take that started at midnight. The ALE
    /// makes the opposite choice deliberately; `TakeSpanTests` pins that.
    @Test func aTakeWithNoTimecodeShowsNoRange() {
        #expect(TakeRowTimes.timecodeRange(of: take(tc: nil, duration: 12))
            == nil)
    }

    /// The length beside it is the transport's own clock, so the panel and the
    /// bar under the picture cannot print different numbers for one take.
    @Test func theRowsLengthIsTheTransportsClock() {
        let subject = take(tc: nil, duration: 59.6)
        #expect(TakeRowTimes.length(of: subject) == "0:59")
        #expect(TakeRowTimes.length(of: subject)
            == ClipTimeText.minutesSeconds.text(subject.durationSeconds))
    }
}
