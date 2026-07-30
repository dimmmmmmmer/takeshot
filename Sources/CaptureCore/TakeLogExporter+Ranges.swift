import Foundation

/// The loop-range sidecar: one row per clip that has an in or an out point,
/// written next to the log and read back when the folder is scanned.
///
/// Its own file for two reasons. The Resolve metadata CSV's schema is what
/// Resolve imports through Media Pool → Import Metadata, so it does not grow
/// columns for our own review state; and the markers sidecar has its own
/// lifecycle and its own owner. Everything else follows `+Markers`: keyed by file
/// name, rewritten wholesale, deleted when nothing has a range.
extension TakeLogExporter {
    public static let rangesFileName = "takeshot-ranges.csv"

    /// Seconds at millisecond precision. The transport works in seconds, and the
    /// RAW engine — which counts frames — converts to seconds before filing, so a
    /// millisecond is finer than one frame at any rate anyone shoots (1/1000 s
    /// against 1/24 s), and the value rounds back to the frame it came from.
    ///
    /// Rows are written in file-name order so that two runs that marked the same
    /// clips produce the same file: a sidecar that reshuffles itself on every
    /// write is noise in the DIT's rsync log.
    public static func rangesCSV(_ ranges: [String: ClipRange]) -> String {
        var lines = ["File Name,In,Out"]
        for name in ranges.keys.sorted() {
            guard let range = ranges[name], !range.isEmpty else { continue }
            lines.append([
                escape(name),
                field(range.inPoint),
                field(range.outPoint),
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// An unset endpoint is an empty cell, not a 0 — a clip looping from its
    /// start to a marked out point has no in point, and 0 would be a mark.
    private static func field(_ seconds: Double?) -> String {
        seconds.map { String(format: "%.3f", $0) } ?? ""
    }

    /// Write the ranges to `directory/takeshot-ranges.csv` (removed when nothing
    /// has a range left, so a folder whose marks were all cleared does not keep a
    /// stale sidecar to restore from).
    @discardableResult
    public static func writeRanges(_ ranges: [String: ClipRange],
                                   toDirectory directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(rangesFileName)
        if ranges.values.allSatisfy(\.isEmpty) {
            try? FileManager.default.removeItem(at: url)
            return url
        }
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        try rangesCSV(ranges).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Ranges from a previously written sidecar, keyed by file name.
    ///
    /// Every guard here drops one row and keeps the rest: this file is plain text
    /// in the record folder and gets opened in Excel, hand-edited and re-saved.
    /// One mangled line must not cost the day's other marks — the same reason the
    /// metadata CSV is decoded lossily.
    public static func parseRanges(csv: String) -> [String: ClipRange] {
        var result: [String: ClipRange] = [:]
        for line in csv.split(whereSeparator: \.isNewline).dropFirst() {
            let fields = parseCSVLine(String(line))
            guard fields.count >= 3, !fields[0].isEmpty else { continue }
            let range = ClipRange(inPoint: seconds(fields[1]),
                                  outPoint: seconds(fields[2]))
            // both ends unreadable is a row that says nothing; a row with one
            // readable end is kept, because half a range is still a mark the
            // operator made
            guard !range.isEmpty else { continue }
            result[fields[0]] = range
        }
        return result
    }

    /// One endpoint. Empty means unset; so does anything that is not a finite,
    /// non-negative number — a NaN or a negative offset would seek the player
    /// somewhere it cannot go.
    private static func seconds(_ field: String) -> Double? {
        let trimmed = field.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let value = Double(trimmed),
              value.isFinite, value >= 0 else { return nil }
        return value
    }
}
