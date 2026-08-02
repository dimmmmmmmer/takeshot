import Foundation

/// Exports the take log to a DaVinci Resolve-compatible CSV
/// (Media Pool → Import Metadata: matched by File Name, "Good Take" is Resolve's checkbox).
///
/// This file is the Resolve metadata CSV and its round trip. The other three
/// jobs the exporter used to do in one file live next to it: `+Report` (the
/// shift report table), `+Markers` (the markers sidecar) and `+CSV` (the RFC
/// 4180 codec all three write through).
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

    /// The header is FROZEN: it is the contract Resolve's Media Pool → Import
    /// Metadata is mapped against, and a column added here silently re-maps
    /// every column after it. The creative fields that do not fit it live in
    /// `takeshot-slate.csv` (see `+Slate`) for exactly that reason.
    public static let resolveCSVHeader = "File Name,Reel Name,Take,Good Take,Comments"

    public static func resolveCSV(takes: [Take]) -> String {
        var lines = [resolveCSVHeader]
        for take in takes {
            lines.append([
                escape(take.url.lastPathComponent),
                escape(take.roll.isEmpty ? take.scene : take.roll),
                // Resolve's Take field is the CREATIVE take, so the slate's own
                // number wins when one was logged; with no slate this is the
                // clip counter, which is what the column always carried.
                String(take.editorialTakeNumber),
                goodTakeField(rating: take.rating),
                escape(commentsField(rating: take.rating, comment: take.comment)),
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Resolve's "Good Take" checkbox column. The rating is ternary and the
    /// column is a checkbox, so the third state has to be the ABSENCE of a
    /// value: "false" means the operator marked the take bad, and writing it for
    /// every unmarked take told Resolve the whole day had been rejected —
    /// including the takes nobody had got round to watching yet.
    ///
    /// Spelled out rather than looked up in a table, like the report's rating
    /// column: a rating added later must break this switch.
    static func goodTakeField(rating: TakeRating) -> String {
        switch rating {
        case .good: return "true"
        case .bad: return "false"
        case .none: return ""
        }
    }

    /// The marker written into Comments for a rejected take. It was "NG" for
    /// the app's whole life; the operator-facing word is "Bad" everywhere now,
    /// and the column is read by people, so the file says what the UI says.
    ///
    /// Only the WRITTEN spelling changed. `badMarkersRead` is what the parser
    /// accepts, and it keeps "NG" forever — logs written by every build before
    /// this one are sitting in record folders, and a shift that reopens one has
    /// to get its ratings back.
    static let badMarkerWritten = "Bad"
    static let badMarkersRead = ["Bad", "NG"]

    /// The Comments column value: a "Bad" marker for rejected takes plus the
    /// free-text comment. "Bad", "Bad: soft focus", or just "soft focus" for
    /// good/unrated takes.
    static func commentsField(rating: TakeRating, comment: String) -> String {
        let text = flattened(comment).trimmingCharacters(in: .whitespacesAndNewlines)
        if rating == .bad {
            return text.isEmpty ? badMarkerWritten : "\(badMarkerWritten): \(text)"
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
            guard fields.count >= 5, !fields[0].isEmpty else { continue }
            let (rating, comment) = parseComments(fields[4], good: fields[3] == "true")
            result[fields[0]] = TakeMeta(rating: rating, comment: comment)
        }
        return result
    }

    /// Ratings only (kept for callers that don't need comments); unrated files
    /// are omitted, matching the original contract.
    public static func parseRatings(csv: String) -> [String: TakeRating] {
        parseMetadata(csv: csv).compactMapValues { $0.rating == .none ? nil : $0.rating }
    }

    /// Split the Comments column into a rating and a free-text comment.
    /// A ticked Good Take → .good; a bad marker ("Bad"/"Bad: text", and the "NG"
    /// this build no longer writes) → .bad; else .none — an EMPTY checkbox and a
    /// written "false" both mean "not a good take", and only the marker says the
    /// operator actively rejected it.
    ///
    /// The checkbox is read FIRST: the marker is written for bad takes only, so
    /// a good take whose comment happens to start with "Bad" (a note about a
    /// shot that was bad on the previous camera, say) keeps both its rating and
    /// its text.
    ///
    /// Both spellings are read forever. Every log written before the rename says
    /// "NG", those files live in record folders on set drives, and dropping the
    /// old spelling would silently turn a day of rejected takes into unrated
    /// ones the next time the folder is opened.
    ///
    /// Matched case-sensitively, exactly as the single spelling was: the marker
    /// is a token this app writes, and a lower-case "bad" in the Comments column
    /// is somebody's note about the light, not a rating.
    static func parseComments(_ value: String, good: Bool) -> (TakeRating, String) {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if good {
            return (.good, trimmed)
        }
        for marker in badMarkersRead {
            if trimmed == marker { return (.bad, "") }
            guard trimmed.hasPrefix(marker + ":") else { continue }
            return (.bad, String(trimmed.dropFirst(marker.count + 1))
                .trimmingCharacters(in: .whitespaces))
        }
        return (.none, trimmed)
    }
}
