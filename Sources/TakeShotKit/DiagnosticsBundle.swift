import CaptureCore
import Foundation

/// Writing the bundle: where it goes, what it is called, and the three files
/// inside it.
///
/// A folder rather than a zip, and no save panel. The owner's condition on this
/// feature was one action — a shooting day is the wrong time to be choosing a
/// directory in a modal panel, and a modal panel is also the one thing here
/// that would freeze the UI while a take is rolling. The other exports in this
/// app do use a save panel, and they are right to: an EDL is a deliverable
/// somebody is filing. This is a black box recorder, and it belongs somewhere
/// predictable.
///
/// Predictable means the Desktop, with a fallback. macOS gates the Desktop
/// behind TCC, so the first attempt on a fresh machine may be refused (or may
/// raise the system's own one-time prompt); Application Support is never gated
/// and is always writable. The bundle therefore tries each candidate in turn
/// and reports the one that took it, rather than failing at the first door.
enum DiagnosticsBundle {
    static let reportFileName = "report.txt"
    static let jsonFileName = "diagnostics.json"
    static let logFileName = "log.txt"

    /// What comes back to the controller. A value with no `Error` in it, so it
    /// can cross out of the background task without wrapping a non-Sendable
    /// error type.
    enum Outcome: Sendable {
        case written(URL)
        case failed(String)
    }

    /// Where a bundle goes when the caller does not say. In order of
    /// preference; the first one that accepts a folder wins.
    ///
    /// Tests always pass a scratch directory instead — nothing in the suite
    /// may write to the operator's Desktop.
    static func defaultParents() -> [URL] {
        var parents: [URL] = []
        let manager = FileManager.default
        if let desktop = manager.urls(for: .desktopDirectory,
                                      in: .userDomainMask).first {
            parents.append(desktop)
        }
        if let support = manager.urls(for: .applicationSupportDirectory,
                                      in: .userDomainMask).first {
            parents.append(support.appendingPathComponent("TakeShot")
                .appendingPathComponent("Diagnostics"))
        }
        parents.append(manager.temporaryDirectory)
        return parents
    }

    /// `TakeShot-diagnostics_<project>_<yymmdd-HHmmss>`.
    ///
    /// The project goes in the name because the operator will have several of
    /// these by the end of a job and a timestamp alone does not say which job.
    /// It is sanitized through the same engine the take names go through, so a
    /// project called "Untitled / Ep 2" cannot produce a path separator.
    static func folderName(project: String, at date: Date) -> String {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyMMdd-HHmmss"
        stamp.locale = Locale(identifier: "en_US_POSIX")
        let sanitized = NamingEngine.sanitize(project)
        let middle = sanitized.isEmpty ? "" : "\(sanitized)_"
        return "TakeShot-diagnostics_\(middle)\(stamp.string(from: date))"
    }

    /// Read the log and write the bundle, off the main actor.
    ///
    /// The snapshot was already taken — this deliberately does no reading of
    /// app state at all. The log query and three file writes take long enough
    /// (tens of milliseconds, occasionally more) that doing them on the main
    /// thread would stutter the UI of an app that may be recording.
    static func produce(_ snapshot: DiagnosticsSnapshot,
                        in parents: [URL]) async -> Outcome {
        await Task.detached(priority: .utility) {
            let log = DiagnosticsLog.recentLines()
            return write(snapshot, log: log, into: parents)
        }.value
    }

    /// Try each candidate parent until one takes the folder.
    static func write(_ snapshot: DiagnosticsSnapshot, log: [String],
                      into parents: [URL]) -> Outcome {
        var lastFailure = "no destination to write to"
        for parent in parents {
            do {
                return .written(try write(snapshot, log: log, under: parent))
            } catch {
                lastFailure = "\(DiagnosticsRedaction.abbreviate(parent)): "
                    + error.localizedDescription
            }
        }
        return .failed(lastFailure)
    }

    /// Write the folder under one parent. Throws if that parent will not have
    /// it — which is the Desktop's TCC refusal, and the reason for the list.
    static func write(_ snapshot: DiagnosticsSnapshot, log: [String],
                      under parent: URL) throws -> URL {
        let folder = parent.appendingPathComponent(
            folderName(project: snapshot.settings["projectName"] ?? "",
                       at: snapshot.generatedAt))
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true)
        try DiagnosticsReport.text(for: snapshot).write(
            to: folder.appendingPathComponent(reportFileName),
            atomically: true, encoding: .utf8)
        try json(for: snapshot).write(
            to: folder.appendingPathComponent(jsonFileName),
            atomically: true, encoding: .utf8)
        try (log.joined(separator: "\n") + "\n").write(
            to: folder.appendingPathComponent(logFileName),
            atomically: true, encoding: .utf8)
        return folder
    }

    /// The same data as the report, machine readable.
    ///
    /// Sorted keys and pretty printing because the owner reads this one too —
    /// "human-readable text/JSON, not a binary blob" was the requirement, and a
    /// single-line JSON blob fails it as surely as a zip would. Slashes are not
    /// escaped, so the paths in it stay paths.
    static func json(for snapshot: DiagnosticsSnapshot) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys,
                                    .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot),
              let text = String(data: data, encoding: .utf8) else {
            return "{\"error\": \"the snapshot could not be encoded\"}"
        }
        return text
    }
}
