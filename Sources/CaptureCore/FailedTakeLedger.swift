import Foundation

/// The takes whose finalize failed AND whose `_FAILED` rename could not be
/// made — remembered off the record volume, so the folder scan can refuse
/// them when the volume comes back.
///
/// **The rename fails exactly when it matters.** A volume that drops mid-take
/// — cable, sleep, power on a bus-powered SSD — is the case a finalize fails
/// in, and the same drop is why `moveItem` cannot rename the file. The
/// half-written .mov keeps the `com.takeshot.origin` tag from its first moov,
/// so after the remount the scan adopted it as a healthy take and wrote it into
/// `takeshot-log.csv`: picture up to the last closed fragment, no tail, and a
/// normal row in the log post reads.
///
/// So the failure is written down where the volume cannot take it with it:
/// Application Support, the way the offload history is. The scan asks here
/// before trusting the tag, and the rename is tried again on the next scan
/// that finds the file — success forgets the entry, because the name then says
/// what this ledger said.
public enum FailedTakeLedger {
    nonisolated(unsafe) public static var fileURL: URL = defaultURL

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("TakeShot/failed-takes.json")
    }

    private static let lock = NSLock()

    /// Remember a take whose rename could not be made.
    public static func record(_ url: URL) {
        lock.withLock {
            var paths = load()
            paths.insert(url.standardizedFileURL.path)
            save(paths)
        }
    }

    /// Whether the scan has been told this file is a failed take.
    public static func contains(_ url: URL) -> Bool {
        lock.withLock { load().contains(url.standardizedFileURL.path) }
    }

    /// The rename finally happened, or the file is gone.
    public static func forget(_ url: URL) {
        lock.withLock {
            var paths = load()
            guard paths.remove(url.standardizedFileURL.path) != nil else { return }
            save(paths)
        }
    }

    private static func load() -> Set<String> {
        guard let data = try? Data(contentsOf: fileURL),
              let paths = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(paths)
    }

    private static func save(_ paths: Set<String>) {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(paths.sorted()) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
