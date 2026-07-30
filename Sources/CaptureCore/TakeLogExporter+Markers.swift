import Foundation

/// The markers sidecar: one row per marker, written next to the log and read
/// back when takes are restored.
///
/// Split out of TakeLogExporter — this is a separate file on disk with its own
/// name, columns and lifecycle (it is deleted when no take has a marker), and it
/// is deliberately not part of the Resolve metadata CSV.
extension TakeLogExporter {
    public static let markersFileName = "takeshot-markers.csv"

    public static func markersCSV(takes: [Take]) -> String {
        var lines = ["File Name,Seconds,Timecode,Color,Note"]
        for take in takes {
            for marker in take.markers {
                lines.append([
                    escape(take.url.lastPathComponent),
                    String(format: "%.3f", marker.seconds),
                    escape(marker.timecodeText),
                    escape(marker.color),
                    escape(flattened(marker.note)),
                ].joined(separator: ","))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Write markers to `directory/takeshot-markers.csv` (removed when empty).
    @discardableResult
    public static func writeMarkers(takes: [Take], toDirectory directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(markersFileName)
        if takes.allSatisfy({ $0.markers.isEmpty }) {
            try? FileManager.default.removeItem(at: url)
            return url
        }
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        try markersCSV(takes: takes).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Markers from a previously written sidecar, keyed by filename.
    public static func parseMarkers(csv: String) -> [String: [TakeMarker]] {
        var result: [String: [TakeMarker]] = [:]
        for line in csv.split(whereSeparator: \.isNewline).dropFirst() {
            let fields = parseCSVLine(String(line))
            guard fields.count >= 3, !fields[0].isEmpty,
                  let seconds = Double(fields[1]) else { continue }
            // Color and Note came later than the first sidecars, so a short row
            // is a valid file, not a broken one.
            let color = fields.count > 3 ? fields[3] : ""
            result[fields[0], default: []].append(TakeMarker(
                seconds: seconds, timecodeText: fields[2],
                color: color.isEmpty ? "orange" : color,
                note: fields.count > 4 ? fields[4] : ""))
        }
        for key in result.keys {
            result[key]?.sort { $0.seconds < $1.seconds }
        }
        return result
    }
}
