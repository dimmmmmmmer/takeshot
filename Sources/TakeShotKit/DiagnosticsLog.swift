import Foundation
import OSLog

/// The bundle's `log.txt`: what this app itself logged in the last hour.
///
/// Only this app. `OSLogStore(scope: .currentProcessIdentifier)` reads the
/// running process's own entries and needs no entitlement and no consent; the
/// `.system` scope would read the whole machine's log, which needs privileges
/// the app does not have and would sweep up other people's data on the way.
/// Filtering to `com.takeshot.app` on top of that is belt and braces — it also
/// keeps the excerpt readable, which is the point of including it at all.
///
/// The lines that matter are already there: the levels decision the pipeline
/// logs on every change (`CapturePipeline.levelsLog`), the folder watcher
/// arming or failing to arm, the playback LUT path, and the remote's bound
/// port. Nothing here logs a PIN.
enum DiagnosticsLog {
    /// The app's own logging subsystem — `CapturePipeline.levelsLog`,
    /// `RemoteServer.log` and every `os_log` call in between use it.
    static let subsystem = "com.takeshot.app"

    /// How far back to reach. An hour covers the setup and the take that went
    /// wrong without turning the excerpt into something nobody scrolls through.
    static let window: TimeInterval = 3600

    /// Hard ceiling on lines, so a pathological log cannot produce a file the
    /// operator has to unzip a text editor to open.
    static let lineLimit = 4000

    /// The excerpt, oldest first. Never throws: a log that cannot be read is a
    /// note in the file, not a failed diagnostic — the rest of the bundle is
    /// still worth having.
    static func recentLines(since window: TimeInterval = window,
                            limit: Int = lineLimit) -> [String] {
        let header = [
            "TakeShot log — subsystem \(subsystem), "
                + "last \(Int(window / 60)) minutes, this process only.",
            "Paths are written with the home folder as \"~\".",
            "",
        ]
        do {
            return try header + entries(since: window, limit: limit)
        } catch {
            return header + [
                "The log store could not be read: \(error.localizedDescription)",
                "",
                "This is normal for a process launched in a way that has no log "
                    + "store of its own; the rest of the bundle is unaffected.",
            ]
        }
    }

    private static func entries(since window: TimeInterval,
                                limit: Int) throws -> [String] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let position = store.position(date: Date(timeIntervalSinceNow: -window))
        let predicate = NSPredicate(format: "subsystem == %@", subsystem)
        let found = try store.getEntries(at: position, matching: predicate)
        var lines: [String] = []
        for entry in found {
            guard let log = entry as? OSLogEntryLog else { continue }
            lines.append(format(log))
            // Kept as the LAST n rather than the first: whatever went wrong
            // did so most recently.
            if lines.count > limit { lines.removeFirst() }
        }
        return lines.isEmpty
            ? ["No entries in this window."]
            : lines
    }

    private static func format(_ entry: OSLogEntryLog) -> String {
        let stamp = timeStamp.string(from: entry.date)
        let level = label(for: entry.level)
        let message = DiagnosticsRedaction.abbreviate(entry.composedMessage)
        return "\(stamp)  \(level)  [\(entry.category)]  \(message)"
    }

    private static func label(for level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: return "DEBUG"
        case .info: return "INFO "
        case .notice: return "NOTE "
        case .error: return "ERROR"
        case .fault: return "FAULT"
        default: return "-----"
        }
    }

    /// Time only: the report's header already carries the date, and a log
    /// excerpt is read against the take that just went wrong.
    private static let timeStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}
