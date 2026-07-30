import Foundation

/// One destination of a running offload: the folder, the file open on it right
/// now, and everything its report will end up saying.
///
/// A class because the copy fans one chunk out to every destination in parallel.
/// Each iteration of the fan-out touches exactly one of these and nothing else,
/// and the array holding them is never mutated while a write is in flight — so
/// the parallel step needs no lock.
///
/// Every method swallows nothing: an error either fails this destination (and
/// only this one) or lands in `mismatches`. The run carries on with whatever is
/// still alive, because on set two SSDs and one dead one is a normal afternoon.
final class OffloadTarget {
    let index: Int
    /// The folder the card's tree is written into.
    let root: URL

    /// Files re-read from this disk and matched — the manifest's contents.
    private(set) var entries: [OffloadEntry] = []
    private(set) var mismatches: [String] = []
    private(set) var filesDone = 0
    private(set) var bytesWritten: Int64 = 0
    /// Why this destination stopped. Non-nil means it is out of the run.
    private(set) var failure: String?

    private var handle: FileHandle?
    /// Where the file being copied is landing (nil between files).
    private var openTarget: URL?
    private let startedAt = Date()
    /// When this destination stopped, if it did — the clock has to stop with it,
    /// or a disk that died in the first minute of an hour-long run reports a
    /// rate of 0.4 MB/s in its summary and nobody can read the number.
    private var endedAt: Date?

    var isAlive: Bool { failure == nil }
    var elapsed: TimeInterval {
        (endedAt ?? Date()).timeIntervalSince(startedAt)
    }
    var verifiedCount: Int { entries.count }

    init(index: Int, root: URL) {
        self.index = index
        self.root = root
    }

    // MARK: - preflight

    /// Create the destination folder and check the volume can hold the card.
    ///
    /// The check is up front on purpose: filling a disk at file 900 of 1000
    /// leaves the operator with an unusable half-copy and an hour gone, and the
    /// numbers to prevent it are free.
    func prepare(bytesNeeded: Int64) {
        do {
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true)
        } catch {
            fail(error.localizedDescription, at: nil)
            return
        }
        guard let available = availableBytes(), available < bytesNeeded else { return }
        fail("not enough space: needs \(OffloadFormat.bytes(bytesNeeded)), "
            + "\(OffloadFormat.bytes(available)) free", at: nil)
    }

    private func availableBytes() -> Int64? {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? root.resourceValues(forKeys: keys),
              let capacity = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return Int64(capacity)
    }

    // MARK: - one file

    /// Open the destination copy. False means this destination is out.
    func begin(_ relativePath: String) -> Bool {
        let candidate = root.appendingPathComponent(relativePath)
        do {
            try FileManager.default.createDirectory(
                at: candidate.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            // Never clobber: two cards with the same DCIM layout are the normal
            // case. The reservation is the process-wide one the take writer
            // uses, so an offload into the record folder cannot land on the
            // name a take is about to take.
            let unique = CapturePipeline.uniqueURL(for: candidate)
            guard FileManager.default.createFile(atPath: unique.path, contents: nil)
            else {
                CapturePipeline.releaseReservation(for: unique)
                throw OffloadError.cannotCreateFile(candidate.lastPathComponent)
            }
            // Recorded BEFORE the handle is opened: the file exists from here on,
            // so an open that fails has to leave `fail` a target to delete. It
            // used to leave a 0-byte file and a stuck reservation behind instead.
            openTarget = unique
            handle = try FileHandle(forWritingTo: unique)
            return true
        } catch {
            fail(error.localizedDescription, at: relativePath)
            return false
        }
    }

    func write(_ chunk: UnsafeRawBufferPointer) {
        guard let handle else { return }
        do {
            try handle.write(contentsOf: chunk)
            bytesWritten += Int64(chunk.count)
        } catch {
            // Out of space arrives here. The partial file goes; a truncated .mov
            // on an SSD is worse than a missing one, because it looks like
            // footage.
            fail(error.localizedDescription, at: openTarget?.lastPathComponent)
        }
    }

    /// Flush, re-read from the disk and compare. This is the only step that can
    /// say the copy is good.
    func verify(_ file: OffloadSourceFile, expecting hash: String,
                copiedBytes: Int64, algorithm: OffloadHashAlgorithm,
                chunkBytes: Int,
                didWriteCopy: (@Sendable (URL) -> Void)? = nil) {
        guard let handle, let written = openTarget else { return }
        filesDone += 1
        do {
            try OffloadIO.flushToDevice(handle)
            try handle.close()
            self.handle = nil
            didWriteCopy?(written)
            let onDisk = try OffloadHasher.hashFile(
                at: written, algorithm: algorithm, bypassCache: true,
                chunkBytes: chunkBytes)
            release()
            guard onDisk == hash else {
                recordMismatch(file.relativePath, copy: written)
                return
            }
            Self.copyTimestamps(from: file.url, to: written)
            entries.append(OffloadEntry(
                relativePath: Self.manifestPath(for: file.relativePath,
                                               written: written),
                size: copiedBytes, hash: hash))
        } catch {
            fail(error.localizedDescription, at: file.relativePath)
        }
    }

    /// The path the manifest lists: the file as WRITTEN on this destination, not
    /// as read off the card.
    ///
    /// `begin` uniquifies a name this destination already holds (a previous card
    /// with the same DCIM layout leaves `A001.mov` behind, so the copy becomes
    /// `A001_2.mov`). A manifest that listed the card's name would point
    /// `ascmhl verify` at that OTHER file and report the footage corrupt — the
    /// hash beside it belongs to the copy, so the path has to as well.
    ///
    /// Only the last component can differ: the folders above it are created under
    /// their own names, so the card-relative parent is reused verbatim rather than
    /// re-derived from the filesystem.
    private static func manifestPath(for relativePath: String,
                                     written: URL) -> String {
        let parent = (relativePath as NSString).deletingLastPathComponent
        return parent.isEmpty
            ? written.lastPathComponent
            : parent + "/" + written.lastPathComponent
    }

    /// The camera's own timestamps travel with the copy.
    ///
    /// A byte-for-byte copy is not the whole job: post sorts dailies by shoot
    /// time, and a card that arrives with today's date on every file has lost
    /// something the original had. `FileManager.copyItem` did this for free —
    /// streaming the bytes ourselves means doing it here. Not fatal if it fails:
    /// some filesystems (exFAT among them) refuse a creation date, and the
    /// footage is already verified by then.
    private static func copyTimestamps(from source: URL, to copy: URL) {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey,
                                         .creationDateKey]
        guard let original = try? source.resourceValues(forKeys: keys) else { return }
        var target = copy
        // Two calls, not one: a filesystem that refuses the creation date would
        // otherwise take the modification date down with it, and the
        // modification date is the one post actually sorts by.
        var modified = URLResourceValues()
        modified.contentModificationDate = original.contentModificationDate
        try? target.setResourceValues(modified)
        var created = URLResourceValues()
        created.creationDate = original.creationDate
        try? target.setResourceValues(created)
    }

    /// The source could not be read: this destination has a partial file that
    /// must not survive.
    func abandonCurrentFile() {
        try? handle?.close()
        handle = nil
        removeOpenTarget()
    }

    // MARK: - failure handling

    private func recordMismatch(_ relativePath: String, copy: URL) {
        mismatches.append("\(relativePath) (checksum mismatch)")
        // Renamed rather than deleted or left alone, following the writer's
        // `*_FAILED.mov` rule: the evidence stays for whoever investigates, the
        // manifest does not list it, and nobody mistakes it for the take.
        let marked = copy.deletingPathExtension().lastPathComponent + "_MISMATCH"
        var renamed = copy.deletingLastPathComponent()
            .appendingPathComponent(marked)
        if !copy.pathExtension.isEmpty {
            renamed.appendPathExtension(copy.pathExtension)
        }
        let target = CapturePipeline.uniqueURL(for: renamed)
        try? FileManager.default.moveItem(at: copy, to: target)
        CapturePipeline.releaseReservation(for: target)
        openTarget = nil
    }

    /// Put this destination out of the run, naming what went wrong.
    func fail(_ reason: String, at path: String?) {
        guard failure == nil else { return }
        failure = path.map { "\($0): \(reason)" } ?? reason
        endedAt = Date()
        try? handle?.close()
        handle = nil
        removeOpenTarget()
    }

    private func removeOpenTarget() {
        guard let openTarget else { return }
        try? FileManager.default.removeItem(at: openTarget)
        CapturePipeline.releaseReservation(for: openTarget)
        self.openTarget = nil
    }

    /// The file exists on disk now, so the filesystem is the authority — the
    /// reservation would otherwise pile up one entry per file on the card.
    private func release() {
        guard let openTarget else { return }
        CapturePipeline.releaseReservation(for: openTarget)
        self.openTarget = nil
    }
}
