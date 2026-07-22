import Foundation

/// Exports the take log to a DaVinci Resolve-compatible CSV
/// (Media Pool → Import Metadata: matched by File Name, "Good Take" is Resolve's checkbox).
public enum TakeLogExporter {
    public static let fileName = "takeshot-log.csv"

    /// Restored per-file metadata: rating + free-text comment.
    public struct TakeMeta: Equatable, Sendable {
        public var rating: TakeRating
        public var comment: String
        public init(rating: TakeRating = .none, comment: String = "") {
            self.rating = rating
            self.comment = comment
        }
    }

    public static func resolveCSV(takes: [Take]) -> String {
        var lines = ["File Name,Reel Name,Take,Good Take,Comments"]
        for take in takes {
            lines.append([
                escape(take.url.lastPathComponent),
                escape(take.roll.isEmpty ? take.scene : take.roll),
                String(take.takeNumber),
                take.rating == .good ? "true" : "false",
                escape(commentsField(rating: take.rating, comment: take.comment)),
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The Comments column value: an "NG" marker for bad takes plus the free-text
    /// comment. "NG", "NG: soft focus", or just "soft focus" for good/unrated takes.
    static func commentsField(rating: TakeRating, comment: String) -> String {
        let text = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        if rating == .bad {
            return text.isEmpty ? "NG" : "NG: \(text)"
        }
        return text
    }

    /// Write the log to `directory/takeshot-log.csv`. Returns the file URL.
    @discardableResult
    public static func write(takes: [Take], toDirectory directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileName)
        try resolveCSV(takes: takes).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Rating + comment from a previously written CSV, keyed by filename.
    /// Used when restoring takes after an app restart.
    public static func parseMetadata(csv: String) -> [String: TakeMeta] {
        var result: [String: TakeMeta] = [:]
        for line in csv.split(whereSeparator: \.isNewline).dropFirst() {
            let fields = parseCSVLine(String(line))
            guard fields.count >= 5 else { continue }
            let name = fields[0]
            guard !name.isEmpty else { continue }
            let goodFlag = fields[3] == "true"
            let (rating, comment) = parseComments(fields[4], good: goodFlag)
            result[name] = TakeMeta(rating: rating, comment: comment)
        }
        return result
    }

    /// Ratings only (kept for callers that don't need comments); unrated files
    /// are omitted, matching the original contract.
    public static func parseRatings(csv: String) -> [String: TakeRating] {
        parseMetadata(csv: csv).compactMapValues { $0.rating == .none ? nil : $0.rating }
    }

    /// Split the Comments column into a rating and a free-text comment.
    /// "NG" / "NG: text" → .bad; a "true" Good Take flag → .good; else .none.
    static func parseComments(_ value: String, good: Bool) -> (TakeRating, String) {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed == "NG" {
            return (.bad, "")
        }
        if trimmed.hasPrefix("NG:") {
            let comment = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            return (.bad, comment)
        }
        return (good ? .good : .none, trimmed)
    }

    /// RFC 4180 escaping: quote values that contain commas/quotes/newlines.
    static func escape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }

    /// RFC 4180 line parser: handles quoted fields with embedded commas/quotes.
    static func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" {
                        current.append("\"") // escaped quote
                        i += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    current.append(c)
                }
            } else if c == "\"" {
                inQuotes = true
            } else if c == "," {
                fields.append(current)
                current = ""
            } else {
                current.append(c)
            }
            i += 1
        }
        fields.append(current)
        return fields
    }
}
