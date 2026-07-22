import Foundation

/// Exports the take log to a DaVinci Resolve-compatible CSV
/// (Media Pool → Import Metadata: matched by File Name, "Good Take" is Resolve's checkbox).
public enum TakeLogExporter {
    public static let fileName = "takeshot-log.csv"

    public static func resolveCSV(takes: [Take]) -> String {
        var lines = ["File Name,Reel Name,Take,Good Take,Comments"]
        for take in takes {
            lines.append([
                escape(take.url.lastPathComponent),
                escape(take.roll.isEmpty ? take.scene : take.roll),
                String(take.takeNumber),
                take.rating == .good ? "true" : "false",
                take.rating == .bad ? "NG" : "",
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Write the log to `directory/takeshot-log.csv`. Returns the file URL.
    @discardableResult
    public static func write(takes: [Take], toDirectory directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileName)
        try resolveCSV(takes: takes).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Ratings from a previously written CSV: filename → good/bad.
    /// Used when restoring takes after an app restart.
    public static func parseRatings(csv: String) -> [String: TakeRating] {
        var result: [String: TakeRating] = [:]
        for line in csv.split(separator: "\n").dropFirst() {
            // our export doesn't quote simple rows; names with commas are rare —
            // just skip those rows
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 5, !fields[0].hasPrefix("\"") else { continue }
            let name = String(fields[0])
            if fields[3] == "true" {
                result[name] = .good
            } else if fields[4] == "NG" {
                result[name] = .bad
            }
        }
        return result
    }

    /// RFC 4180 escaping: quote values that contain commas/quotes/newlines.
    static func escape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }
}
