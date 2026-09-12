import Foundation
import Testing

@testable import CaptureCore

/// **Which takes belong to which shift** (owner: "у нас же если проект длинный
/// тейки удачные могут быть по разным дням").
///
/// The two cases that matter are the ones the calendar gets wrong: a night
/// shoot running through midnight is ONE shift, and two shifts either side of
/// a turnaround are two even when they share a date. Everything is written in
/// LOCAL wall-clock time, because that is what both of those are about.
@Suite struct ShiftsTests {
    /// A moment on the 2026 shoot, local: `at(day: 11, hour: 20)` is 20:00 on
    /// the 11th of September wherever this runs.
    private func at(day: Int, hour: Int, minute: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(
            year: 2026, month: 9, day: day, hour: hour, minute: minute))
            ?? Date(timeIntervalSince1970: 0)
    }

    private func take(_ index: Int, _ moment: Date) -> Take {
        Take(url: URL(fileURLWithPath: "/tmp/CLIP\(index).mov"),
             scene: "", roll: "A001", takeNumber: index,
             startTimecode: Timecode(hours: 10, minutes: 0, seconds: 0,
                                     frames: 0, fps: 25),
             durationSeconds: 10, recordedAt: moment)
    }

    @Test func nothingSplitsIntoNothing() {
        #expect(Shifts.split([]).isEmpty)
    }

    @Test func oneShiftStaysOneShiftInTheOrderItWasGiven() {
        let takes = [take(1, at(day: 12, hour: 8)),
                     take(2, at(day: 12, hour: 9)),
                     take(3, at(day: 12, hour: 10))]
        let days: [Shifts.Day] = Shifts.split(takes)
        #expect(days.count == 1)
        #expect(days[0].takes.map(\.takeNumber) == [1, 2, 3])
        #expect(days[0].start == takes[0].recordedAt)
        #expect(days[0].end == takes[2].recordedAt)
    }

    /// A meal, a company move and a lighting reset are all inside one working
    /// day, and none of them reaches turnaround.
    @Test func aLongBreakInsideADayIsStillOneDay() {
        let days = Shifts.split([take(1, at(day: 12, hour: 8)),
                                 take(2, at(day: 12, hour: 13, minute: 50))])
        #expect(days.count == 1, "a five-hour break inside the shift split it")
    }

    /// Turnaround: ten to twelve hours by contract, and never under eight.
    @Test func aTurnaroundStartsANewShift() {
        let days = Shifts.split([take(1, at(day: 12, hour: 8)),
                                 take(2, at(day: 12, hour: 9)),
                                 take(3, at(day: 13, hour: 8)),
                                 take(4, at(day: 13, hour: 9))])
        #expect(days.count == 2)
        #expect(days[0].takes.map(\.takeNumber) == [1, 2])
        #expect(days[1].takes.map(\.takeNumber) == [3, 4])
    }

    /// **The case the calendar gets wrong.** A night shoot that starts at 20:00
    /// and wraps at 05:00 is ONE shooting day, dated by the evening it began —
    /// splitting on the date would cut it in half at midnight, in the middle of
    /// the working night.
    @Test func aNightShootThroughMidnightIsOneShift() {
        let days: [Shifts.Day] = Shifts.split([
            take(1, at(day: 11, hour: 20)), take(2, at(day: 11, hour: 23)),
            take(3, at(day: 12, hour: 1)), take(4, at(day: 12, hour: 5))])
        #expect(days.count == 1, "midnight split the night")
        #expect(days[0].takes.count == 4)
        // and it is filed under the evening it began, not the morning it ended
        #expect(Shifts.stamp(days[0].start) == "2026-09-11")
        #expect(Shifts.stamp(days[0].end) == "2026-09-12")
    }

    /// …and its mirror: two shifts that share a calendar date are two shifts.
    /// A night that wrapped at 02:00 and a day that started at 14:00 is a
    /// twelve-hour turnaround, which is a turnaround.
    @Test func twoShiftsOnOneDateAreStillTwo() {
        let days: [Shifts.Day] = Shifts.split([
            take(1, at(day: 12, hour: 2)), take(2, at(day: 12, hour: 14)),
            take(3, at(day: 12, hour: 15))])
        #expect(days.count == 2)
        #expect(days.map { Shifts.stamp($0.start) }
            == ["2026-09-12", "2026-09-12"])
        #expect(days[0].takes.map(\.takeNumber) == [1])
        #expect(days[1].takes.map(\.takeNumber) == [2, 3])
    }

    /// The gap is measured from the LAST take of the shift so far, not from
    /// its first — a shift running fourteen hours does not split itself.
    @Test func theGapIsMeasuredFromTheLastTakeNotTheFirst() {
        let days = Shifts.split((0..<8).map {
            take($0, at(day: 12, hour: 8 + $0 * 2))
        })
        #expect(days.count == 1, "a fourteen-hour shift split itself")
    }

    /// **The order inside a shift is the caller's, not this function's.** An
    /// exporter that quietly re-ordered a list somebody chose would move a
    /// clip in a document nobody re-reads — so a single shift comes back
    /// holding exactly what was given, in exactly that order, however its
    /// stamps happen to sort.
    @Test func oneShiftIsHandedBackUntouched() {
        let scrambled = [take(3, at(day: 12, hour: 10)),
                         take(1, at(day: 12, hour: 8)),
                         take(2, at(day: 12, hour: 9))]
        #expect(Shifts.split(scrambled).first?.takes.map(\.takeNumber)
            == [3, 1, 2])
        // …and the shift's own start and end are still measured, not taken
        // from the ends of the list
        #expect(Shifts.split(scrambled).first?.start == scrambled[1].recordedAt)
        #expect(Shifts.split(scrambled).first?.end == scrambled[0].recordedAt)
    }

    /// The same rule across a turnaround: membership is measured, order is
    /// kept. A folder's contents arrive in whatever order the scan produced.
    @Test func takesOutOfOrderAreGroupedButNotReordered() {
        let days = Shifts.split([take(4, at(day: 13, hour: 9)),
                                 take(2, at(day: 12, hour: 9)),
                                 take(3, at(day: 13, hour: 8)),
                                 take(1, at(day: 12, hour: 8))])
        #expect(days.count == 2)
        // grouped by when they were shot, ordered as they were handed in
        #expect(days[0].takes.map(\.takeNumber) == [2, 1])
        #expect(days[1].takes.map(\.takeNumber) == [4, 3])
    }

    /// Two takes stamped the same second must not swap places between two
    /// exports of one unchanged day — a sort with no tiebreak is not stable.
    @Test func takesStampedTheSameSecondKeepTheirOrder() {
        let moment = at(day: 12, hour: 8)
        let takes = [take(7, moment), take(8, moment), take(9, moment)]
        for _ in 0..<8 {
            #expect(Shifts.split(takes).first?.takes.map(\.takeNumber)
                == [7, 8, 9])
        }
    }
}
