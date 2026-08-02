import Foundation

/// The creative sidecar: scene, shot, take-within-the-scene and the logging
/// description, one row per take that has any of them.
///
/// Its own file, and not four more columns on `takeshot-log.csv`, for the
/// reason stated at the top of that writer: the Resolve metadata CSV's schema
/// is FROZEN — it is what Media Pool → Import Metadata maps against, and a
/// column inserted into it re-maps every column after it in every folder ever
/// written. Everything else follows the ranges and markers sidecars: keyed by
/// file name, rewritten wholesale, removed when nothing has a slate left.
///
/// Scene/shot/take also live INSIDE each .mov (see `TakeWriter`). This file is
/// not a duplicate of that: the embedded copy is what the take was slated with
/// when it was recorded, and this one is what the operator has since corrected
/// it to — a finalized recording is never rewritten, so the two are allowed to
/// disagree and the sidecar is the newer of the pair.
extension TakeLogExporter {
    public static let slateFileName = "takeshot-slate.csv"

    /// The sidecar's header. Not frozen the way the Resolve CSV is — nothing
    /// but this app reads it — but stated once so the writer and the parser
    /// cannot drift.
    public static let slateCSVHeader = "File Name,Scene,Shot,Take,Description"

    /// One row per take with something logged. Written in file-name order so
    /// two runs over the same day produce the same bytes — a sidecar that
    /// reshuffles itself is noise in the DIT's rsync log.
    public static func slateCSV(takes: [Take]) -> String {
        var lines = [slateCSVHeader]
        for take in takes.sorted(by: { $0.url.lastPathComponent
            < $1.url.lastPathComponent }) where hasSlateRow(take) {
            lines.append([
                escape(take.url.lastPathComponent),
                escape(flattened(take.slate.scene)),
                escape(flattened(take.slate.shot)),
                take.slate.take > 0 ? String(take.slate.take) : "",
                escape(flattened(take.logDescription)),
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Whether a take has anything to say here. The description counts even
    /// with no slate: a logged description on an unslated take is still the
    /// operator's work and must survive a relaunch.
    static func hasSlateRow(_ take: Take) -> Bool {
        !take.slate.isEmpty || !take.logDescription.isEmpty
    }

    /// Write `directory/takeshot-slate.csv`, removing it when the day has no
    /// creative metadata at all — a folder whose slates were all cleared must
    /// not keep a stale sidecar to restore from.
    @discardableResult
    public static func writeSlates(takes: [Take],
                                   toDirectory directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(slateFileName)
        guard takes.contains(where: hasSlateRow) else {
            try? FileManager.default.removeItem(at: url)
            return url
        }
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        try slateCSV(takes: takes).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// What one file's row carried. A struct rather than a tuple because the
    /// restore hands it around and three of its four members are strings.
    public struct SlateRow: Equatable, Sendable {
        public var slate: SlateMetadata
        public var logDescription: String

        public init(slate: SlateMetadata = .empty, logDescription: String = "") {
            self.slate = slate
            self.logDescription = logDescription
        }
    }

    /// Rows from a previously written sidecar, keyed by file name.
    ///
    /// Every guard drops one row and keeps the rest, like the ranges parser:
    /// this is plain text in the record folder and it gets opened in Excel,
    /// hand-edited and saved back. One mangled line must not cost the day.
    public static func parseSlates(csv: String) -> [String: SlateRow] {
        var result: [String: SlateRow] = [:]
        for line in csv.split(whereSeparator: \.isNewline).dropFirst() {
            let fields = parseCSVLine(String(line))
            guard fields.count >= 5, !fields[0].isEmpty else { continue }
            let row = SlateRow(
                slate: SlateMetadata(scene: fields[1], shot: fields[2],
                                     take: takeNumberField(fields[3])),
                logDescription: fields[4])
            // a row that says nothing is not a row — it would only overwrite
            // whatever the file's own embedded slate could still supply
            guard !row.slate.isEmpty || !row.logDescription.isEmpty else {
                continue
            }
            result[fields[0]] = row
        }
        return result
    }

    /// The Take cell. Empty means "not logged"; so does anything that is not a
    /// positive whole number — a 0 or a negative would read back as a take
    /// number the slate never had.
    private static func takeNumberField(_ field: String) -> Int {
        let trimmed = field.trimmingCharacters(in: .whitespaces)
        guard let value = Int(trimmed), value > 0 else { return 0 }
        return value
    }
}
