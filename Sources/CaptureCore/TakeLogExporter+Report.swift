import Foundation

/// The shift report: the full data table production paperwork wants, one row per
/// take with start/end/duration timecode, rating, comment and markers.
///
/// Split out of TakeLogExporter — this table is for humans and has no round
/// trip, where the Resolve CSV next door is a round trip and carries only what
/// Resolve reads.
extension TakeLogExporter {
    /// End TC of a take: start TC advanced by the recorded frames.
    ///
    /// The arithmetic is `TakeSpan`, shared with the ALE and the takes panel;
    /// what is decided HERE is that a take with no start timecode has no end
    /// to print. A shift report is read by a human, and `00:00:12;01` against
    /// a take the camera gave no timecode for is a number that looks like a
    /// position and is not one — the table prints an em dash instead. The ALE
    /// makes the opposite choice for a machine-read reason of its own; see
    /// `ALEExporter.span`.
    public static func endTimecode(of take: Take) -> Timecode? {
        guard take.startTimecode != nil else { return nil }
        return TakeSpan.of(take).end
    }

    /// Take length as timecode at the take's own rate ("00:00:12:07").
    ///
    /// `TakeRuntime.lengthTimecode` does the counting, on the take's OWN rate
    /// — a 23.976 take counted at 24 came out a frame long every 41 s — and
    /// the same function answers for the MARKED length in the columns below,
    /// so two lengths in one row cannot be counted two ways.
    public static func durationTimecode(of take: Take) -> String {
        TakeRuntime.lengthTimecode(take.durationSeconds, of: take)
    }

    /// The report table, labelled in `labels`' language.
    ///
    /// This CSV is production paperwork for HUMANS and has no round trip, so
    /// its headers and rating words follow the app language (owner item 21).
    /// The Resolve sidecar next door (`takeshot-log.csv`, `+CSV`) is the exact
    /// opposite — a frozen machine schema — and is deliberately not touched.
    /// The labels are injected because CaptureCore is localization-free; the
    /// default keeps every existing caller's output English.
    public static func reportCSV(_ material: TakeRuntime.ReportMaterial,
                                 labels: ShiftReportCSVLabels = .english)
        -> String {
        var lines = [labels.header.map(escape).joined(separator: ",")]
        // Empty for a single-shift report, which is nearly all of them: a
        // column repeating one date down a page says nothing, and the sheet's
        // own header already carries it.
        let shifts = TakeRuntime.shiftStamps(of: material.takes)
        let formatter = DateFormatter()
        // numeric and language-neutral on purpose — a date that changes shape
        // with the language is not comparable across two days' reports
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for take in material.takes {
            // spelled out rather than looked up in a table: a rating added
            // later must break this switch, not silently export blank
            let rating: String
            switch take.rating {
            case .good: rating = labels.good
            case .bad: rating = labels.bad
            case .none: rating = ""
            }
            // Appended in three pieces rather than concatenated with `+`:
            // one expression spanning three array literals is the shape the
            // older compiler on CI times out type-checking (docs/ARCHITECTURE.md).
            var cells: [String] = [
                shifts[take.id] ?? "",
                escape(take.url.lastPathComponent),
                escape(take.roll),
                String(take.takeNumber),
                // the creative columns sit next to the clip they belong to: the
                // production office reads this table by scene, not by file
                escape(flattened(take.slate.scene)),
                escape(flattened(take.slate.shotText)),
                take.slate.take > 0 ? String(take.slate.take) : "",
                take.startTimecode?.description ?? "",
                endTimecode(of: take)?.description ?? "",
                durationTimecode(of: take),
            ]
            cells.append(contentsOf: markCells(
                of: take, range: material.ranges[TakeRuntime.key(take)]))
            cells.append(contentsOf: [
                escape(rating),
                escape(flattened(take.comment)),
                escape(flattened(take.logDescription)),
                escape(take.markers.map(\.timecodeText).joined(separator: "; ")),
                formatter.string(from: take.recordedAt),
            ])
            lines.append(cells.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The three in/out cells of one row: where the marked part starts, where
    /// it ends, and how long it is.
    ///
    /// All three empty for a take nothing narrows, which is most of them —
    /// `TakeRuntime.window` decides that, so a row's cells and the runtime on
    /// the header are the same judgement. The two positions are printed
    /// CLAMPED, i.e. as the window that was actually counted: a mark left
    /// past the end of a take it was made against (a clip re-recorded under
    /// the same name, a sidecar edited by hand) would otherwise print an out
    /// point beyond the take's own End TC on the row above it.
    ///
    /// `Duration` next door stays the RECORDED length. Two columns that
    /// disagree is the point — one says what was rolled and the other what
    /// was kept, and a report that quietly overwrote the first with the second
    /// would lose the only record of how long the camera ran.
    private static func markCells(of take: Take, range: ClipRange?) -> [String] {
        guard let window = TakeRuntime.window(of: take, range: range) else {
            return ["", "", ""]
        }
        return [
            TakeRuntime.markTimecode(of: take, atSecond: window.start),
            TakeRuntime.markTimecode(of: take, atSecond: window.end),
            TakeRuntime.lengthTimecode(window.end - window.start, of: take),
        ]
    }
}

/// The shift-report CSV's translatable words: the column headers, in column
/// order, and the two rating values. Injected by the app in its UI language;
/// the English default is what the file says with no app around it.
public struct ShiftReportCSVLabels: Sendable, Equatable {
    /// One label per column — the writer above defines the order.
    ///
    /// `Shift` is FIRST because it is the outermost grouping: a project that
    /// ran over several nights is read shift by shift, and a column the reader
    /// sorts by belongs where a sort starts. It is empty on every row of a
    /// single-shift report, which is nearly all of them.
    ///
    /// The three in/out columns sit with the other timings rather than at the
    /// end: a reader checking a take's marked part against what was rolled
    /// reads five cells side by side instead of across the row.
    public var header = ["Shift",
                         "File Name", "Roll", "Clip", "Scene", "Shot", "Take",
                         "Start TC", "End TC", "Duration",
                         "In", "Out", "Selected", "Rating",
                         "Comments", "Description", "Markers", "Recorded At"]
    public var good = "GOOD"
    public var bad = "BAD"

    public init() {}

    public static let english = ShiftReportCSVLabels()
}
