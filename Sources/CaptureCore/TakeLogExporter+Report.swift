import Foundation

/// The shift report: the full data table production paperwork wants, one row per
/// take with start/end/duration timecode, rating, comment and markers.
///
/// Split out of TakeLogExporter — this table is for humans and has no round
/// trip, where the Resolve CSV next door is a round trip and carries only what
/// Resolve reads.
extension TakeLogExporter {
    /// End TC of a take: start TC advanced by the recorded frames.
    public static func endTimecode(of take: Take) -> Timecode? {
        guard let start = take.startTimecode else { return nil }
        return Timecode(frameNumber: start.frameNumber + durationFrames(of: take, at: start),
                        fps: start.fps, isDropFrame: start.isDropFrame)
    }

    /// Take length as timecode at the take's own rate ("00:00:12:07").
    public static func durationTimecode(of take: Take) -> String {
        // no start TC (manual take on a source without one): count at 25 fps,
        // which is what the field showed before the take could carry a rate
        let rate = take.startTimecode ?? fallbackRate
        return Timecode(frameNumber: durationFrames(of: take, at: rate),
                        fps: max(1, rate.fps),
                        isDropFrame: rate.isDropFrame).description
    }

    /// The recorded length in frames, counted on `rate`'s own timebase (see
    /// `realRate(of:)` — a drop-frame rate is not its nominal value).
    private static func durationFrames(of take: Take, at rate: Timecode) -> Int {
        frameOffset(seconds: take.durationSeconds, at: rate)
    }

    /// The report table, labelled in `labels`' language.
    ///
    /// This CSV is production paperwork for HUMANS and has no round trip, so
    /// its headers and rating words follow the app language (owner item 21).
    /// The Resolve sidecar next door (`takeshot-log.csv`, `+CSV`) is the exact
    /// opposite — a frozen machine schema — and is deliberately not touched.
    /// The labels are injected because CaptureCore is localization-free; the
    /// default keeps every existing caller's output English.
    public static func reportCSV(takes: [Take],
                                 labels: ShiftReportCSVLabels = .english)
        -> String {
        var lines = [labels.header.map(escape).joined(separator: ",")]
        let formatter = DateFormatter()
        // numeric and language-neutral on purpose — a date that changes shape
        // with the language is not comparable across two days' reports
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for take in takes {
            // spelled out rather than looked up in a table: a rating added
            // later must break this switch, not silently export blank
            let rating: String
            switch take.rating {
            case .good: rating = labels.good
            case .bad: rating = labels.bad
            case .none: rating = ""
            }
            lines.append([
                escape(take.url.lastPathComponent),
                escape(take.roll),
                String(take.takeNumber),
                // the creative columns sit next to the clip they belong to: the
                // production office reads this table by scene, not by file
                escape(flattened(take.slate.scene)),
                escape(flattened(take.slate.shot)),
                take.slate.take > 0 ? String(take.slate.take) : "",
                take.startTimecode?.description ?? "",
                endTimecode(of: take)?.description ?? "",
                durationTimecode(of: take),
                escape(rating),
                escape(flattened(take.comment)),
                escape(flattened(take.logDescription)),
                escape(take.markers.map(\.timecodeText).joined(separator: "; ")),
                formatter.string(from: take.recordedAt),
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// The shift-report CSV's translatable words: the column headers, in column
/// order, and the two rating values. Injected by the app in its UI language;
/// the English default is what the file says with no app around it.
public struct ShiftReportCSVLabels: Sendable, Equatable {
    /// One label per column — the writer above defines the order.
    public var header = ["File Name", "Roll", "Clip", "Scene", "Shot", "Take",
                         "Start TC", "End TC", "Duration", "Rating",
                         "Comments", "Description", "Markers", "Recorded At"]
    public var good = "GOOD"
    public var bad = "BAD"

    public init() {}

    public static let english = ShiftReportCSVLabels()
}
