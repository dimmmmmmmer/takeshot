import Foundation

/// The markers sidecar: one row per marker, written next to the log and read
/// back when takes are restored.
///
/// Split out of TakeLogExporter — this is a separate file on disk with its own
/// name, columns and lifecycle (it is deleted when no take has a marker), and it
/// is deliberately not part of the Resolve metadata CSV.
///
/// The position is a TIMECODE and nothing else. The file used to carry a Seconds
/// column next to it, i.e. two records of one value, written from two different
/// sources: the marker's own timecode text, and an offset measured against a
/// take start that is re-read from the file on every restart. Nothing kept them
/// in step, and the timecode is the one an operator, an editor and Resolve all
/// read. Turning it back into a player position needs the take that owns the
/// marker, which is why reading is two steps — `parseMarkerRows` for the file,
/// then `markers(_:of:)` once the take is known.
///
/// This file is the on-disk layout: the columns, the header, and what an older
/// file's columns mean. The timecode ↔ offset conversion either end of it is in
/// `+MarkerTime`, which the shift report and the controller share.
extension TakeLogExporter {
    public static let markersFileName = "takeshot-markers.csv"

    /// One marker row exactly as the sidecar carries it: no offset, because the
    /// file does not have one.
    public struct MarkerRow: Equatable, Sendable {
        public var timecodeText: String
        public var color: String
        public var note: String
        /// Set only when reading a sidecar old enough to have the Seconds
        /// column. It is the fallback for the rows an old file can carry that
        /// this build's Timecode column cannot express: an empty Timecode cell
        /// (a marker flagged while recording a source with no timecode at all),
        /// and an absolute camera timecode on a take whose own start timecode is
        /// no longer readable. `markers(_:of:)` reaches for it only when the
        /// timecode fails; what gets written back is a derived one
        /// (see `markerTimecode`).
        public var legacySeconds: Double?

        public init(timecodeText: String, color: String = "orange",
                    note: String = "", legacySeconds: Double? = nil) {
            self.timecodeText = timecodeText
            self.color = color
            self.note = note
            self.legacySeconds = legacySeconds
        }
    }

    static let markersHeader = "File Name,Timecode,Color,Note"

    /// The whole sidecar: the takes' markers, then the markers of everything
    /// else in the record folder.
    ///
    /// `other` is keyed by FILE NAME, which is the key this file has always
    /// used — the loop-range sidecar next door is the same shape for the same
    /// reason. It exists because the marker UI is in the transport, the
    /// transport runs for any clip the operator opens, and a clip that landed in
    /// the folder from a card is a clip somebody wants to flag a moment in. Such
    /// a file has no `Take` and no start timecode of its own, so its positions
    /// are offsets from zero (see `markerTimecode(of:startingAt:)`).
    ///
    /// Its rows are written in file-name order so that two runs over the same
    /// marks produce the same file — a sidecar that reshuffles itself on every
    /// write is noise in the DIT's rsync log. The takes keep their own order,
    /// which is the shooting order.
    public static func markersCSV(takes: [Take],
                                  other: [String: [TakeMarker]] = [:]) -> String {
        var lines = [markersHeader]
        for take in takes {
            for marker in take.markers {
                lines.append(markerRow(marker, named: take.url.lastPathComponent,
                                       startingAt: take.startTimecode))
            }
        }
        for name in other.keys.sorted() {
            for marker in other[name] ?? [] {
                lines.append(markerRow(marker, named: name, startingAt: nil))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func markerRow(_ marker: TakeMarker, named name: String,
                                  startingAt start: Timecode?) -> String {
        [
            escape(name),
            escape(markerTimecode(of: marker, startingAt: start)),
            escape(marker.color),
            escape(flattened(marker.note)),
        ].joined(separator: ",")
    }

    /// Write markers to `directory/takeshot-markers.csv` (removed when empty).
    @discardableResult
    public static func writeMarkers(takes: [Take],
                                    other: [String: [TakeMarker]] = [:],
                                    toDirectory directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(markersFileName)
        if takes.allSatisfy({ $0.markers.isEmpty }),
           other.values.allSatisfy(\.isEmpty) {
            try? FileManager.default.removeItem(at: url)
            return url
        }
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        try markersCSV(takes: takes, other: other)
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Marker rows from a previously written sidecar, keyed by filename.
    public static func parseMarkerRows(csv: String) -> [String: [MarkerRow]] {
        let records = parseCSVRecords(csv)
        guard let header = records.first else { return [:] }
        let columns = MarkerColumns(header: header)
        var result: [String: [MarkerRow]] = [:]
        for fields in records.dropFirst() {
            let name = unguarded(columns.name.value(in: fields))
            let timecode = columns.timecode.value(in: fields)
            let legacy = Double(columns.seconds.value(in: fields))
            guard !name.isEmpty, !timecode.isEmpty || legacy != nil else { continue }
            // Color and Note came later than the first sidecars, so a short row
            // is a valid file, not a broken one.
            let color = columns.color.value(in: fields)
            result[name, default: []].append(MarkerRow(
                timecodeText: timecode,
                color: color.isEmpty ? "orange" : color,
                note: unguarded(columns.note.value(in: fields)),
                legacySeconds: legacy))
        }
        return result
    }

    /// Where each field is, by header name. The layout has already changed once
    /// (the Seconds column is gone), and a shift that starts on one build and
    /// finishes on the next must not lose its markers — so the header decides
    /// where to look instead of a fixed offset. Seconds is still looked for, for
    /// the one thing only an old file can carry: see `MarkerRow.legacySeconds`.
    private struct MarkerColumns {
        let name: Column
        let timecode: Column
        let color: Column
        let note: Column
        let seconds: Column

        init(header: [String]) {
            name = Column(of: "File Name", in: header)
            timecode = Column(of: "Timecode", in: header)
            color = Column(of: "Color", in: header)
            note = Column(of: "Note", in: header)
            seconds = Column(of: "Seconds", in: header)
        }
    }

    /// One column's position, or nothing when the file does not have it.
    private struct Column {
        let index: Int?

        init(of title: String, in header: [String]) {
            index = header.firstIndex {
                $0.trimmingCharacters(in: .whitespaces)
                    .caseInsensitiveCompare(title) == .orderedSame
            }
        }

        func value(in fields: [String]) -> String {
            guard let index, fields.indices.contains(index) else { return "" }
            return fields[index]
        }
    }
}
