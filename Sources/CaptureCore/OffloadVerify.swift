import Foundation

/// One file the disk did not answer for, and why.
public struct OffloadVerifyFault: Sendable, Equatable, Identifiable {
    public var relativePath: String
    public var reason: String

    public var id: String { relativePath }

    public init(relativePath: String, reason: String) {
        self.relativePath = relativePath
        self.reason = reason
    }
}

/// Live state of a verify pass, for the sheet.
public struct OffloadVerifyProgress: Sendable, Equatable {
    public var filesTotal: Int
    public var filesDone: Int
    public var bytesTotal: Int64
    public var bytesRead: Int64
    /// Relative path of the file being hashed right now.
    public var currentFile: String
    public var elapsed: TimeInterval
    public var isCancelling: Bool

    public init(filesTotal: Int, filesDone: Int, bytesTotal: Int64,
                bytesRead: Int64, currentFile: String, elapsed: TimeInterval,
                isCancelling: Bool) {
        self.filesTotal = filesTotal
        self.filesDone = filesDone
        self.bytesTotal = bytesTotal
        self.bytesRead = bytesRead
        self.currentFile = currentFile
        self.elapsed = elapsed
        self.isCancelling = isCancelling
    }

    public var megabytesPerSecond: Double {
        OffloadMetrics.megabytesPerSecond(bytes: bytesRead, seconds: elapsed)
    }
}

/// What re-reading a disk against its manifest found.
///
/// Four lists, deliberately not three: a file that verified, one that is there
/// and wrong, one that is listed and gone, and one that is on the disk and in no
/// manifest are four different things to do next, and collapsing any pair of
/// them loses the fact that decides which.
public struct OffloadVerifyReport: Sendable, Equatable {
    public let root: URL
    public let manifest: URL
    public let algorithm: OffloadHashAlgorithm
    public let span: OffloadSpan
    /// Listed, re-read, and the checksum matched.
    public var verified: [String]
    /// Listed and on the disk, but not what the manifest says it is.
    public var mismatched: [OffloadVerifyFault]
    /// Listed and not on the disk at all.
    public var missing: [String]
    /// On the disk and in no manifest. Not a fault by itself — an operator who
    /// dropped a LUT or a sound roll next to the footage did nothing wrong — but
    /// it is the only warning that a second card was offloaded into this folder
    /// and its own manifest has since been lost.
    public var extra: [String]
    /// Folders the disk would not let us walk. The manifest side of the report
    /// is unaffected (those files are opened by name, not by enumeration); what
    /// this limits is how much of `extra` could be seen.
    public var scanFailures: [String]
    public var bytesRead: Int64
    public var wasCancelled: Bool

    public init(root: URL, manifest: URL, algorithm: OffloadHashAlgorithm,
                span: OffloadSpan, verified: [String] = [],
                mismatched: [OffloadVerifyFault] = [], missing: [String] = [],
                extra: [String] = [], scanFailures: [String] = [],
                bytesRead: Int64 = 0, wasCancelled: Bool = false) {
        self.root = root
        self.manifest = manifest
        self.algorithm = algorithm
        self.span = span
        self.verified = verified
        self.mismatched = mismatched
        self.missing = missing
        self.extra = extra
        self.scanFailures = scanFailures
        self.bytesRead = bytesRead
        self.wasCancelled = wasCancelled
    }

    /// Every file the manifest lists is on the disk and is what it says it is.
    ///
    /// Strays do not enter into it: they say nothing about the footage the
    /// manifest covers, and an operator who has to clear a `.DS_Store` off a
    /// disk before the tool will say "intact" learns to ignore the tool. A run
    /// that stopped early is not intact either — most of the disk was never
    /// read, and "verified" over that is the one lie that matters here.
    public var isIntact: Bool {
        !wasCancelled && mismatched.isEmpty && missing.isEmpty
    }

    /// Everything the manifest lists.
    public var filesListed: Int {
        verified.count + mismatched.count + missing.count
    }

    public var megabytesPerSecond: Double {
        OffloadMetrics.megabytesPerSecond(bytes: bytesRead,
                                          seconds: span.elapsed)
    }
}

/// Checking a disk against the ASC MHL manifest an offload left on it.
///
/// The offload verifies every file as it lands; this is the other half of that
/// promise, weeks later. The SSD comes back from post, or has been in a case in
/// a van all season, and the question is whether what is on it is still what the
/// manifest says. It is the answer `ascmhl verify` or Silverstack would give,
/// without either of them having to be on the set machine.
///
/// Read through `F_NOCACHE`, like the offload's own verify pass and for the same
/// reason: a file still sitting in the unified page cache verifies RAM, not the
/// disk somebody is about to ship.
///
/// Synchronous, and blocking file I/O from end to end — the app runs it on the
/// offload queue and `progress` arrives on that same thread.
public enum OffloadVerify {
    /// The files an offload writes BESIDE the copy rather than as part of it.
    ///
    /// The manifest cannot list itself, and the summary — text and picture
    /// alike — is written after it, so none of them is ever in the manifest and
    /// all of them would be reported as strays on every single verify. Nothing
    /// here is footage, and a stray list that cries wolf three times per run
    /// stops being read.
    ///
    /// Two shapes, and they mirror where the engine puts each artifact: the
    /// manifest under `ascmhl/`, the receipt in the ROOT of the copy — hence
    /// the "no slash in the path" guard, which is what keeps a file the camera
    /// happened to name `offload-summary_*.txt` three folders down from being
    /// waved through as one of ours.
    public static func isReportFile(_ relativePath: String) -> Bool {
        if relativePath.hasPrefix(OffloadMHL.folderName + "/") { return true }
        guard !relativePath.contains("/"),
              relativePath.hasPrefix(OffloadSummary.filePrefix) else {
            return false
        }
        return relativePath.hasSuffix(".txt")
            || relativePath.hasSuffix(".\(OffloadReportCard.fileExtension)")
    }

    public static func run(
        root: URL,
        cancellation: OffloadCancellation = OffloadCancellation(),
        chunkBytes: Int = OffloadIO.defaultChunkBytes,
        progress: @escaping @Sendable (OffloadVerifyProgress) -> Void = { _ in })
        throws -> OffloadVerifyReport {
        guard let url = OffloadManifestReader.latest(in: root) else {
            throw OffloadVerifyError.noManifest(root.lastPathComponent)
        }
        return try OffloadVerifyRun(root: root,
                                    manifest: OffloadManifestReader.read(url),
                                    cancellation: cancellation,
                                    chunkBytes: chunkBytes,
                                    progress: progress).execute()
    }
}

/// The state of one verify pass. A class for the same reason `OffloadRun` is
/// one: small steps over shared state beat one function threading a dozen
/// `inout` parameters.
private final class OffloadVerifyRun {
    private let root: URL
    private let manifest: OffloadManifest
    private let cancellation: OffloadCancellation
    private let chunkBytes: Int
    private let publish: (OffloadVerifyProgress) -> Void
    private let started = Date()
    private let bytesTotal: Int64

    private var verified: [String] = []
    private var mismatched: [OffloadVerifyFault] = []
    private var missing: [String] = []
    private var bytesRead: Int64 = 0
    private var currentFile = ""
    private var filesDone = 0
    private var lastPublished = Date.distantPast

    init(root: URL, manifest: OffloadManifest,
         cancellation: OffloadCancellation, chunkBytes: Int,
         progress: @escaping (OffloadVerifyProgress) -> Void) {
        self.root = root
        self.manifest = manifest
        self.cancellation = cancellation
        self.chunkBytes = chunkBytes
        self.publish = progress
        self.bytesTotal = manifest.entries.reduce(0) { $0 + $1.size }
    }

    func execute() -> OffloadVerifyReport {
        report(force: true)
        for entry in manifest.entries {
            if cancellation.isCancelled { break }
            currentFile = entry.relativePath
            check(entry)
            filesDone += 1
            report(force: true)
        }
        // Cancel only counts if it actually cut the pass short — the same rule
        // the offload uses. Stop pressed during the last file leaves a complete
        // answer, and reporting that as "stopped early" is a false alarm.
        let stoppedShort = cancellation.isCancelled
            && filesDone < manifest.entries.count
        let strays = stoppedShort ? (extra: [], failures: [String]()) : survey()
        return OffloadVerifyReport(
            root: root, manifest: manifest.url, algorithm: manifest.algorithm,
            span: OffloadSpan(started: started, finished: Date()),
            verified: verified, mismatched: mismatched, missing: missing,
            extra: strays.extra, scanFailures: strays.failures,
            bytesRead: bytesRead, wasCancelled: stoppedShort)
    }

    // MARK: - one file

    private func check(_ entry: OffloadEntry) {
        let url = root.appendingPathComponent(entry.relativePath)
        // The reader refuses a climbing path; this is the belt to its braces —
        // the RESOLVED file has to sit under the resolved destination, whatever
        // the text looked like.
        // LEXICAL, not through the filesystem: `standardizedFileURL` resolves
        // symlinks for a path that exists and leaves one that does not, so a
        // deleted file under a `/var` → `/private/var` root came out "outside
        // the destination" instead of missing. `standardized` folds `..` and
        // touches nothing on disk, which is the only question being asked.
        let inside = root.standardized.path
        guard url.standardized.path.hasPrefix(inside + "/") else {
            mismatched.append(OffloadVerifyFault(
                relativePath: entry.relativePath,
                reason: "the manifest names a path outside the destination"))
            return
        }
        guard let size = regularFileSize(at: url) else {
            missing.append(entry.relativePath)
            return
        }
        // Length first: a truncated copy is the common way a file goes wrong,
        // and saying by how much is worth more to whoever has to explain it
        // than reading a gigabyte to arrive at "checksum mismatch".
        guard size == entry.size else {
            mismatched.append(OffloadVerifyFault(
                relativePath: entry.relativePath,
                reason: "size is \(size) bytes, manifest says \(entry.size)"))
            return
        }
        do {
            let digest = try hash(url)
            guard digest == entry.hash else {
                mismatched.append(OffloadVerifyFault(
                    relativePath: entry.relativePath,
                    reason: "checksum mismatch"))
                return
            }
            verified.append(entry.relativePath)
        } catch {
            // A file the disk will not give up is not a missing file: it is
            // still there, and whether it is intact is unknown — which is the
            // one thing this tool must not report as "verified".
            mismatched.append(OffloadVerifyFault(
                relativePath: entry.relativePath,
                reason: error.localizedDescription))
        }
    }

    /// Streamed rather than `OffloadHasher.hashFile`, so a single 50 GB file
    /// still moves the progress bar while it is being read.
    private func hash(_ url: URL) throws -> String {
        var hasher = OffloadHasher(manifest.algorithm)
        try OffloadIO.readChunks(of: url, bypassCache: true,
                                 chunkBytes: chunkBytes) { chunk in
            hasher.update(chunk)
            bytesRead += Int64(chunk.count)
            report(force: false)
        }
        return hasher.finalize()
    }

    /// The size of a regular file, or nil for anything that is not one. A
    /// directory or a symlink standing where the manifest says a movie should be
    /// is a missing movie, whatever else it is.
    private func regularFileSize(at url: URL) -> Int64? {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              values.isRegularFile == true else { return nil }
        return Int64(values.fileSize ?? 0)
    }

    // MARK: - what the manifest does not list

    /// Walk the tree and subtract the manifest from it.
    ///
    /// Skipped after a cancel: the pass read part of the disk, and a stray list
    /// derived from a complete walk beside a checked list that stops halfway
    /// reads as though the walk had found something the check missed.
    private func survey() -> (extra: [String], failures: [String]) {
        let scan = OffloadEngine.scan(root)
        let listed = Set(manifest.entries.map(\.relativePath))
        let extra = scan.files.map(\.relativePath)
            .filter { !listed.contains($0) && !OffloadVerify.isReportFile($0) }
        return (extra.sorted(), scan.failures)
    }

    // MARK: - progress

    /// Five times a second, and always on a file boundary — the same budget the
    /// offload publishes on, and for the same reason: a disk of small files
    /// would otherwise flood the main thread with work nobody can see.
    private func report(force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastPublished) >= 0.2 else { return }
        lastPublished = now
        publish(OffloadVerifyProgress(
            filesTotal: manifest.entries.count, filesDone: filesDone,
            bytesTotal: bytesTotal,
            bytesRead: bytesRead, currentFile: currentFile,
            elapsed: now.timeIntervalSince(started),
            isCancelling: cancellation.isCancelled))
    }
}
