import CaptureCore
import Foundation

/// The two numbers under a take's name in the takes panel: where it runs from
/// and to, and how long it is.
///
/// Its own type rather than two free functions in `TakeListView.swift`, for the
/// reason `SlateTakeField` and `TakeLogDraft` are types: these are the numbers
/// the operator reads off the panel and back to the script supervisor, and
/// nothing could ask them while they lived beside a view body. The range
/// turned out to be wrong the first time anything could ask it — see
/// `TakeSpan`.
enum TakeRowTimes {
    /// "10:00:00;00 – 10:10:00;00", or nil when the take carries no start
    /// timecode.
    ///
    /// nil rather than a zero-based range, and that is the panel's own choice
    /// rather than a shared one: the row already shows the LENGTH next to
    /// this, so a take with no timecode loses nothing by showing no range,
    /// while `00:00:00:00 – 00:00:12:00` on a row beside nine real timecodes
    /// reads as a take that started at midnight. The ALE makes the opposite
    /// choice, for a machine-read reason of its own (`ALEExporter.span`).
    ///
    /// The en dash is punctuation and not a word, so it is the same in both
    /// languages; the timecodes are digits. Nothing here is localized.
    static func timecodeRange(of take: Take) -> String? {
        guard let start = take.startTimecode else { return nil }
        return "\(start.description) – \(TakeSpan.of(take).end.description)"
    }

    /// "0:12" — the take's length, the same clock the transport under it
    /// counts on (`ClipTimeText`).
    static func length(of take: Take) -> String {
        ClipTimeText.minutesSeconds.text(take.durationSeconds)
    }
}
