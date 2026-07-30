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
        let rate = take.startTimecode
            ?? Timecode(frameNumber: 0, fps: 25, isDropFrame: false)
        return Timecode(frameNumber: durationFrames(of: take, at: rate),
                        fps: max(1, rate.fps),
                        isDropFrame: rate.isDropFrame).description
    }

    /// The recorded length in frames, counted on `rate`'s own timebase: a
    /// drop-frame rate runs at 1000/1001 of its nominal value, so the real rate
    /// is what converts seconds to frames.
    private static func durationFrames(of take: Take, at rate: Timecode) -> Int {
        let realRate = Double(rate.fps) * (rate.isDropFrame ? 1000.0 / 1001.0 : 1)
        return Int((take.durationSeconds * realRate).rounded())
    }

    public static func reportCSV(takes: [Take]) -> String {
        var lines = ["File Name,Roll,Clip,Start TC,End TC,Duration,Rating,Comments,Markers,Recorded At"]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for take in takes {
            // spelled out rather than looked up in a table: a rating added
            // later must break this switch, not silently export blank
            let rating: String
            switch take.rating {
            case .good: rating = "GOOD"
            case .bad: rating = "NG"
            case .none: rating = ""
            }
            lines.append([
                escape(take.url.lastPathComponent),
                escape(take.roll),
                String(take.takeNumber),
                take.startTimecode?.description ?? "",
                endTimecode(of: take)?.description ?? "",
                durationTimecode(of: take),
                rating,
                escape(flattened(take.comment)),
                escape(take.markers.map(\.timecodeText).joined(separator: "; ")),
                formatter.string(from: take.recordedAt),
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
