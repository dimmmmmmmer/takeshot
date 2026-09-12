import Foundation

/// **A long project's takes are not all from one day** (owner: "у нас же если
/// проект длинный тейки удачные могут быть по разным дням. может нам учитывать
/// многосменность в экспорте хмл и в экспорте шифт репортов").
///
/// The app's take list is a FOLDER, and a folder that is not wiped between
/// shifts holds every shift that was shot into it. Every document that leaves
/// set was written as if it held one: a timeline laid the circled takes of
/// three nights end to end as one sequence, and a shift report totalled three
/// days of footage under one date.
///
/// # Where a shift ends, and why it is not the calendar
///
/// A shooting day is dated by the day it STARTED — the night of the 11th is
/// the 11th's shooting day, whatever the clock said when the last take went in
/// — so splitting on the calendar date cuts every night shoot in half, at
/// midnight, which is the middle of the working night.
///
/// What separates two shifts is TURNAROUND: the rest between them, which is
/// ten to twelve hours by every contract on a professional set and never less
/// than eight. What separates two takes inside one shift is a meal, a company
/// move or a lighting reset — two to three hours at the very worst. The gap
/// between those two ranges is wide, and `turnaround` sits in it.
///
/// So the rule needs no setting and no clock convention: a gap of six hours or
/// more is a new shift, and nothing else is.
public enum Shifts {
    /// A gap this long between one take and the next starts a new shift.
    ///
    /// Six hours. Long enough that no break inside a working day reaches it —
    /// a company move plus a meal is two to three — and short enough that no
    /// real turnaround is shorter, since ten to twelve hours of rest between
    /// shifts is contractual and eight is the floor anyone has ever worked to.
    public static let turnaround: TimeInterval = 6 * 3600

    /// The takes of one shift, in the order they were recorded.
    public struct Day: Equatable, Sendable {
        public var takes: [Take]
        /// When the shift started — the moment its FIRST take was recorded,
        /// which is the date the office files the day under.
        public var start: Date
        /// When its last take was recorded. The shift ran a little past this;
        /// nothing here pretends to know the wrap time.
        public var end: Date

        public init(takes: [Take], start: Date, end: Date) {
            self.takes = takes
            self.start = start
            self.end = end
        }
    }

    /// Split a take list into shifts.
    ///
    /// **Which shift a take belongs to is measured; what ORDER the takes come
    /// back in is the caller's.** A gap can only be read off a list in time
    /// order, so membership is decided on a sorted copy — but each shift then
    /// comes back holding its takes in the order they were handed in, and that
    /// is not a detail. An exporter that quietly re-ordered a caller's list
    /// would rewrite a timeline whose order somebody chose, and the way that
    /// shows up is a clip in the wrong place in a document nobody re-reads.
    ///
    /// So a list from ONE shift comes back as one Day holding exactly what was
    /// given, in exactly that order — which is why every writer here could
    /// adopt this without a single existing document changing.
    ///
    /// Ties in the sort keep the caller's order too, so two takes stamped the
    /// same second cannot land in different shifts between two runs.
    public static func split(_ takes: [Take]) -> [Day] {
        let ordered = takes.enumerated()
            .sorted { ($0.element.recordedAt, $0.offset)
                < ($1.element.recordedAt, $1.offset) }
            .map(\.element)
        var groups: [Day] = []
        for take in ordered {
            guard var day = groups.last,
                  take.recordedAt.timeIntervalSince(day.end) < turnaround else {
                groups.append(Day(takes: [take], start: take.recordedAt,
                                  end: take.recordedAt))
                continue
            }
            day.takes.append(take)
            day.end = take.recordedAt
            groups[groups.count - 1] = day
        }
        // Membership came off the sorted copy; the takes themselves come back
        // out of the CALLER's list, in the caller's order. One group is the
        // same statement as any other — the filter hands back everything that
        // was given, unmoved — so there is no special case here and no second
        // path for the ordinary day to drift down.
        return groups.map { group in
            let members = Set(group.takes.map(\.id))
            return Day(takes: takes.filter { members.contains($0.id) },
                       start: group.start, end: group.end)
        }
    }

    /// The date a shift is filed under, as digits: `2026-09-12`.
    ///
    /// `en_US_POSIX` and numeric on purpose. This lands in a sequence NAME
    /// inside a timeline and in a heading over a table, where it is sorted and
    /// compared rather than read as prose — a date that changes shape with the
    /// application's language sorts nowhere, which is the same argument
    /// `CaptureController.reportDateStamp` makes about a file name. The shift
    /// report's own HEADER is the opposite and stays in the app's language:
    /// that one is a sentence.
    public static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
}
