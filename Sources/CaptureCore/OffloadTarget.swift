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
    /// What an earlier interrupted run of THIS card left here, by the card's own
    /// relative path. Empty unless the plan asked to resume and the stamp beside
    /// this folder's newest manifest attests it to this card.
    private var claimed: [String: OffloadEntry] = [:]
    /// Non-nil once the run has asked this destination what it holds, which is
    /// also what makes the resume block appear in its summary.
    private var resume: OffloadResumeFacts?
    private var isResuming = false
    /// What the claimed files occupy on this disk already — the preflight's space
    /// check subtracts it, or a nearly full disk that holds most of the card
    /// would be refused for wanting room it does not need.
    private(set) var claimedBytes: Int64 = 0
    private var reused = 0
    private(set) var bytesReused: Int64 = 0
    /// Copies that were sitting where this run had to write and were replaced
    /// from the card rather than trusted.
    private var replaced: [String] = []
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

    /// What resuming did here, or nil if it was never asked for.
    /// Files verified while the kernel refused `F_NOCACHE` on this volume.
    var unbypassedVerifies: Int = 0

    var resumeFacts: OffloadResumeFacts? {
        guard var facts = resume else { return nil }
        facts.reused = reused
        facts.reusedBytes = bytesReused
        facts.replaced = replaced
        return facts
    }

    init(index: Int, root: URL) {
        self.index = index
        self.root = root
    }

    // MARK: - resume

    /// Take on what a survey found here (see `OffloadResume`).
    ///
    /// A refused offer is adopted too, with nothing claimed: the destination's
    /// own summary then states WHY everything was copied, which is the
    /// difference between a tool that was careful and one that ignored the
    /// question.
    func adopt(_ offer: OffloadResumeOffer) {
        isResuming = offer.isUsable
        resume = OffloadResumeFacts(claimed: offer.files,
                                    refusal: offer.refusal?.reason)
        guard isResuming else { return }
        for entry in offer.claimed { claimed[entry.relativePath] = entry }
        claimedBytes = offer.bytes
    }

    /// Is this file already here, and provably the right bytes?
    ///
    /// The gate is the HASH and never the size. A truncated file has a plausible
    /// size and the wrong hash — this codebase already treats a length that
    /// changed mid-copy as reason not to wipe a card — so the copy is re-read off
    /// the disk with the cache bypassed and hashed against the manifest that
    /// claimed it. Anything else at all (gone, short, unreadable, one bit out)
    /// returns false and is copied from the card again.
    ///
    /// A match joins `entries`, so the manifest this run writes lists the WHOLE
    /// set on the disk rather than only what moved this time. A manifest that
    /// omitted files which are present would be worse than none for whoever
    /// receives the drive, and the generations are how the verify tool decides
    /// what to check.
    func reuse(_ file: OffloadSourceFile, algorithm: OffloadHashAlgorithm,
               chunkBytes: Int) -> Bool {
        guard let entry = claimed[file.relativePath] else { return false }
        let url = root.appendingPathComponent(file.relativePath)
        guard Self.regularFileSize(at: url) == entry.size,
              let digest = try? OffloadHasher.hashFile(
                at: url, algorithm: algorithm, bypassCache: true,
                chunkBytes: chunkBytes),
              digest == entry.hash
        else { return false }
        filesDone += 1
        reused += 1
        bytesReused += entry.size
        entries.append(entry)
        return true
    }

    /// The size of a regular file, or nil for anything that is not one — a
    /// directory standing where a movie should be is not a movie.
    private static func regularFileSize(at url: URL) -> Int64? {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              values.isRegularFile == true else { return nil }
        return Int64(values.fileSize ?? 0)
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
            replaceStaleCopy(at: candidate, of: relativePath)
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

    /// On a RESUMED destination only: a file sitting where this run is about to
    /// write goes, rather than being written beside as `…_2`.
    ///
    /// The never-clobber rule above exists because two cards with the same DCIM
    /// layout are normal — the file already there might be another card's
    /// footage. Here it cannot be: the stamp beside this folder's manifest
    /// attests the copy to THIS card, and the file has already failed the hash
    /// gate (or was never in the manifest at all, which is what the write the
    /// disk died in the middle of leaves behind). Keeping it would leave a
    /// truncated .mov next to the good copy under a `_2` name, and a truncated
    /// file on an SSD is the outcome this codebase calls worse than a missing
    /// one — it looks like footage.
    ///
    /// Never silent: every path taken this way is listed in this destination's
    /// summary and counted in its resume facts.
    ///
    /// **Counted only once the delete has actually happened.** It used to be
    /// counted first and deleted with a `try?`, so a destination that was
    /// read-only, or a file some other process had open, left the truncated
    /// copy in place under the REAL name, put the good one beside it as `_2`,
    /// and printed the real name under RE-COPIED. The operator reads a clean
    /// report and wipes the card — which is the exact outcome the paragraph
    /// above calls worse than a missing file, arrived at through the report
    /// rather than through the disk.
    private func replaceStaleCopy(at candidate: URL, of relativePath: String) {
        guard isResuming, Self.regularFileSize(at: candidate) != nil else {
            return
        }
        do {
            try FileManager.default.removeItem(at: candidate)
            replaced.append(relativePath)
        } catch {
            // The stale copy is still there, so this destination cannot be
            // trusted for this file at all: failing it is what keeps the
            // summary and the disk saying the same thing.
            fail(error.localizedDescription, at: relativePath)
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
            var bypassRefused = false
            let onDisk = try OffloadHasher.hashFile(
                at: written, algorithm: algorithm, bypassCache: true,
                chunkBytes: chunkBytes, cacheBypassRefused: &bypassRefused)
            // Counted, not fatal — see `OffloadDestinationResult
            // .unbypassedVerifies`. A destination that refuses the bypass
            // refuses it for every file, so this is a per-VOLUME fact arriving
            // one file at a time.
            if bypassRefused { unbypassedVerifies += 1 }
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
