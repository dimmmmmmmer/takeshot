import Foundation

/// **How much footage the circled takes actually came to** (owner: "в шифт
/// репорте пиши еще плис по хорошим тейкам сколько хрона вышло и чтоб если был
/// выбран ин/аут тоже писало это").
///
/// The day's total at the top of a shift report is the sum of everything that
/// was shot, which is what was ROLLED. What the office is asking for is a
/// different number — what was KEPT — and it is not the same sum with the
/// rejected takes dropped: a circled take carries an in/out the operator marked
/// during review, and the part between those two marks is the part that goes
/// forward. Both numbers belong on the sheet, because a runtime quoted without
/// saying whether it is trimmed is a number nobody downstream can check.
///
/// Two decisions are worth stating, since both are places a total can silently
/// go wrong:
///
/// - **a mark that selects nothing is not a selection.** An out point at or
///   before the in point is a broken mark, not a zero-length take, and
///   subtracting the whole take from the day's runtime is a worse answer than
///   ignoring the mark. Same for a mark on a take whose length could not be
///   read.
/// - **a non-finite duration contributes nothing rather than poisoning the
///   sum.** `CMTime.seconds` of an indefinite time is NaN and a single NaN
///   makes the whole total NaN — the same trap `ClipTimeText` documents, one
///   level up, where the clock that survives it is only asked afterwards.
public enum TakeRuntime {
    /// The material one report covers: the day's takes and the in/out marks
    /// filed against them.
    ///
    /// One value rather than two parameters because they are one thing — the
    /// marks are keyed to the takes BY FILE NAME (`TransportModel.key`, which
    /// is `url.lastPathComponent`, and `key(_:)` below has to agree with it),
    /// so a caller that passes one day's takes with another day's marks has
    /// made a mistake no signature would have caught. Every report writer
    /// wants both.
    public struct ReportMaterial: Equatable, Sendable {
        public var takes: [Take]
        public var ranges: [String: ClipRange]

        public init(_ takes: [Take], ranges: [String: ClipRange] = [:]) {
            self.takes = takes
            self.ranges = ranges
        }
    }

    /// What the circled takes add up to, both ways.
    public struct Selects: Equatable, Sendable {
        /// How many takes are circled.
        public var count = 0
        /// Their length as recorded, marks ignored.
        public var whole = 0.0
        /// Their length as marked — the number the office wants.
        public var marked = 0.0
        /// How many of them carry a mark that actually shortens them. A range
        /// covering the whole take is not counted: it changes no number, and
        /// saying "in/out" on the strength of it would make the sheet claim a
        /// trim that is not there.
        public var markedCount = 0

        public init() {}

        /// An in/out was applied and it took something off.
        public var isTrimmed: Bool { markedCount > 0 }
    }

    /// The key a range table files this take's marks under.
    public static func key(_ take: Take) -> String { take.url.lastPathComponent }

    /// **The part of `take` the marks select**, as a pair of offsets clamped
    /// into the take — or nil when nothing narrows it.
    ///
    /// nil is the answer for all four of the ways a mark says nothing: no mark
    /// at all, a take whose length could not be read, an out point at or
    /// before the in point, and a window that spans the whole take. Every
    /// surface that prints or counts a mark goes through here, so the runtime
    /// on the header, the "in/out" count beside it and the cells in the rows
    /// cannot come to disagree about which takes were trimmed.
    public static func window(of take: Take,
                              range: ClipRange?) -> (start: Double, end: Double)? {
        let whole = length(take.durationSeconds)
        guard let range, whole > 0 else { return nil }
        let start = min(length(range.inPoint ?? 0), whole)
        let end = min(length(range.outPoint ?? whole), whole)
        guard end > start, end - start < whole else { return nil }
        return (start, end)
    }

    /// The length of `take` as it will be used: the marked window when there
    /// is one, else the whole take.
    public static func seconds(of take: Take, range: ClipRange?) -> Double {
        window(of: take, range: range).map { $0.end - $0.start }
            ?? length(take.durationSeconds)
    }

    /// **The day's footage**: every take on the sheet, marks ignored — what
    /// the camera rolled, against `selects` which is what was kept.
    ///
    /// Here rather than spelled at the header because of the guard: a plain
    /// `reduce` poisons on one take whose length came back non-finite, and
    /// the clock that draws the total only rescues NaN (`ClipTimeText` clamps
    /// it to zero) — an infinite one it renders as an enormous number of
    /// hours. Either way one damaged file used to cost the whole day's figure
    /// instead of its own.
    public static func footage(of takes: [Take]) -> Double {
        takes.reduce(0) { $0 + length($1.durationSeconds) }
    }

    /// The circled takes of `material`, totalled both ways.
    ///
    /// The filter is here rather than at the call site so that "circled" is
    /// one statement: the header's good/bad tally and this runtime have to be
    /// counting the same takes.
    public static func selects(of material: ReportMaterial) -> Selects {
        var result = Selects()
        for take in material.takes where take.rating == .good {
            let whole = length(take.durationSeconds)
            let marked = window(of: take, range: material.ranges[key(take)])
            result.count += 1
            result.whole += whole
            result.marked += marked.map { $0.end - $0.start } ?? whole
            if marked != nil { result.markedCount += 1 }
        }
        return result
    }

    /// A position inside `take` as timecode on the take's own clock.
    ///
    /// Through the MARKER's own converter, so a mark and a marker in the same
    /// row of the report cannot land on different clocks: both are absolute
    /// for a take that carried timecode and both count from zero for one that
    /// did not.
    public static func markTimecode(of take: Take, atSecond seconds: Double) -> String {
        TakeLogExporter.markerTimecode(of: TakeMarker(seconds: seconds), in: take)
    }

    /// A LENGTH in seconds as timecode at the take's own rate ("00:00:12:07").
    ///
    /// `TakeLogExporter.durationTimecode` is this asked about the whole take —
    /// it forwards here, so the marked length and the recorded length in one
    /// row are counted by one piece of arithmetic.
    public static func lengthTimecode(_ seconds: Double, of take: Take) -> String {
        // no start TC (manual take on a source without one): count at 25 fps,
        // which is what the field showed before the take could carry a rate
        let rate = take.startTimecode ?? TakeLogExporter.fallbackRate
        return Timecode(
            frameNumber: TakeLogExporter.frameOffset(seconds: seconds, for: take),
            fps: max(1, rate.fps), isDropFrame: rate.isDropFrame).description
    }

    /// A duration that can be added up: nothing a damaged file reported, and
    /// never negative.
    private static func length(_ seconds: Double) -> Double {
        seconds.isFinite ? max(0, seconds) : 0
    }
}
