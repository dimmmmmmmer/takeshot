import Foundation

/// Verified offload of a camera card to any number of destinations at once.
///
/// The shape of it, which is the whole feature:
///
/// - **Read once, write N.** Each source file is streamed exactly once and the
///   chunk is handed to every destination in parallel. Reading the card N times
///   is N times as slow and N times the wear on the only copy that exists.
/// - **Hash on the read stream.** The source digest costs nothing extra; hashing
///   the card again afterwards would.
/// - **Verify by re-reading the destination.** The copy is flushed to the device
///   and read back through `F_NOCACHE`, then hashed. A comparison against
///   anything still in memory verifies RAM, not the disk the card is about to be
///   wiped against.
/// - **Destinations fail independently.** A disk that fills up or unplugs takes
///   itself out of the run, with the reason in its own summary; the others
///   finish.
///
/// Synchronous by design — it is blocking file I/O from end to end, and the app
/// runs it on a utility queue. `progress` is called on that same thread.
public enum OffloadEngine {
    /// Every file on the card.
    ///
    /// A card copy must be COMPLETE: hidden files included (the camera's own
    /// index files live there), and a directory that cannot be walked is a
    /// failure rather than a silent skip — a skipped folder is how footage
    /// disappears between a wiped card and a delivery.
    public static func scan(_ source: URL)
        -> (files: [OffloadSourceFile], failures: [String]) {
        var files: [OffloadSourceFile] = []
        var failures: [String] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: source, includingPropertiesForKeys: keys, options: [],
            errorHandler: { url, error in
                failures.append("\(url.lastPathComponent) "
                    + "(\(error.localizedDescription))")
                return true
            }) else {
            return ([], ["\(source.lastPathComponent) (cannot be opened)"])
        }
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true { continue }
            guard values?.isRegularFile == true else {
                // A symlink or a device node cannot be copied as a byte stream,
                // and pretending it was copied is the dangerous option.
                failures.append("\(url.lastPathComponent) (not a regular file)")
                continue
            }
            files.append(OffloadSourceFile(
                url: url, relativePath: relativePath(of: url, under: source),
                size: Int64(values?.fileSize ?? 0)))
        }
        // Sorted so the manifest of a given card is the same file every time,
        // whatever order the filesystem happened to hand the tree back in.
        return (files.sorted { $0.relativePath < $1.relativePath }, failures)
    }

    /// The card-relative path of a file, built from path components rather than
    /// by trimming a prefix off the string: a source whose path ends in a slash
    /// (a volume root) or differs in normalization left the old string version
    /// with an absolute path, which then landed the copy outside the tree it was
    /// supposed to go into.
    public static func relativePath(of file: URL, under root: URL) -> String {
        let fileParts = file.standardizedFileURL.resolvingSymlinksInPath()
            .pathComponents
        let rootParts = root.standardizedFileURL.resolvingSymlinksInPath()
            .pathComponents
        guard fileParts.count > rootParts.count,
              Array(fileParts.prefix(rootParts.count)) == rootParts
        else { return file.lastPathComponent }
        return fileParts.dropFirst(rootParts.count).joined(separator: "/")
    }

    /// Run the plan to completion (or to the operator's Cancel) and return
    /// everything both the UI and the two report files need.
    @discardableResult
    public static func run(
        _ plan: OffloadPlan,
        cancellation: OffloadCancellation = OffloadCancellation(),
        progress: @escaping @Sendable (OffloadProgress) -> Void = { _ in })
        -> OffloadReport {
        OffloadRun(plan: plan, cancellation: cancellation,
                   progress: progress).execute()
    }
}

/// The state of one run. A class so the steps can be small methods over shared
/// state instead of one function threading a dozen `inout` parameters.
private final class OffloadRun {
    private let plan: OffloadPlan
    private let cancellation: OffloadCancellation
    private let publish: (OffloadProgress) -> Void
    private let started = Date()

    private var files: [OffloadSourceFile] = []
    private var bytesTotal: Int64 = 0
    private var scanFailures: [String] = []
    private var sourceFailures: [String] = []
    private var targets: [OffloadTarget] = []
    private var currentFile = ""
    private var filesProcessed = 0
    private var lastPublished = Date.distantPast
    /// Which card this run is reading, as a later run would have to recognise it.
    /// Stamped beside every manifest so that a run interrupted by a lost disk can
    /// be resumed — and so that a run of a DIFFERENT card into the same folder
    /// cannot be mistaken for one (see `OffloadResume`).
    private var identity = OffloadCardIdentity(volumeUUID: nil, source: "",
                                               files: 0, bytes: 0)
    /// Cancel that actually cut the run short — see `execute`.
    private var stoppedShort = false

    init(plan: OffloadPlan, cancellation: OffloadCancellation,
         progress: @escaping (OffloadProgress) -> Void) {
        self.plan = plan
        self.cancellation = cancellation
        self.publish = progress
    }

    func execute() -> OffloadReport {
        let scan = OffloadEngine.scan(plan.source)
        files = scan.files
        scanFailures = scan.failures
        bytesTotal = files.reduce(0) { $0 + $1.size }
        identity = OffloadCardIdentity.of(
            source: plan.source,
            card: OffloadVolume(files: files.count, bytes: bytesTotal))
        targets = plan.destinations.enumerated().map {
            OffloadTarget(index: $0.offset, root: $0.element)
        }
        // Surveyed BEFORE the space check, because it changes the answer: a disk
        // that already holds 400 GB of a 500 GB card needs room for 100 GB, and
        // a preflight that asked for the whole card would refuse the very
        // destination resume exists to rescue. A claimed file that later fails
        // the hash gate is removed before it is rewritten, so its space is not
        // needed twice.
        adoptPreviousRuns()
        for target in targets {
            target.prepare(bytesNeeded: bytesTotal - target.claimedBytes)
        }
        report(force: true)

        for file in files {
            // Cancel is checked between files, never inside one: a half-written
            // file on an SSD is the one outcome worse than no file.
            if cancellation.isCancelled { break }
            currentFile = file.relativePath
            copy(file)
            filesProcessed += 1
            report(force: true)
        }
        // Cancel only counts if it actually cut the run short. Stop pressed
        // during the last file still leaves every file on the card copied and
        // verified, and "CANCELLED — do NOT wipe the card" over a complete
        // offload is a false alarm — which is how real alarms stop being read.
        stoppedShort = cancellation.isCancelled && filesProcessed < files.count
        // Built once, and once the last file is in: every destination's summary
        // now states the same finish time as the report does. Each used to take
        // a fresh `Date()` as it was written, so three SSDs came away with three
        // different answers to when the run ended.
        let run = runFacts(finished: Date())
        let results = targets.map { finalize($0, run: run) }
        return OffloadReport(run: run, filesProcessed: filesProcessed,
                             wasCancelled: stoppedShort, destinations: results)
    }

    // MARK: - resume

    /// Ask every destination what an earlier interrupted run of this same card
    /// left on it.
    ///
    /// One manifest parse per destination and no file contents read — the proof
    /// is per file, in `OffloadTarget.reuse`, as each file comes up. Independent
    /// per destination by construction: the disk that finished and the disk that
    /// died are surveyed separately and neither's answer reaches the other.
    private func adoptPreviousRuns() {
        guard plan.resume else { return }
        for target in targets {
            target.adopt(OffloadResume.survey(
                card: files, identity: identity, destination: target.root,
                algorithm: plan.algorithm))
        }
    }

    // MARK: - one file, N destinations

    private func copy(_ file: OffloadSourceFile) {
        var open: [OffloadTarget] = []
        for target in targets where target.isAlive {
            // A destination that already holds this file — re-read off its own
            // disk and matching its own manifest — is neither read for nor
            // written to. It is not in `open`, so if every destination has it the
            // card is never even opened.
            if target.reuse(file, algorithm: plan.algorithm,
                            chunkBytes: plan.chunkBytes) { continue }
            if target.begin(file.relativePath) { open.append(target) }
        }
        guard !open.isEmpty else { return }
        var hasher = OffloadHasher(plan.algorithm)
        var copiedBytes: Int64 = 0
        do {
            // The card is read through F_NOCACHE as well: nothing here is ever
            // read twice, so caching it would evict everything else on the
            // machine to no purpose.
            try OffloadIO.readChunks(of: file.url, bypassCache: true,
                                     chunkBytes: plan.chunkBytes) { chunk in
                hasher.update(chunk)
                copiedBytes += Int64(chunk.count)
                fanOut(chunk, to: open.filter(\.isAlive))
                report(force: false)
            }
        } catch {
            sourceFailures.append("\(file.relativePath) "
                + "(\(error.localizedDescription))")
            for target in open { target.abandonCurrentFile() }
            return
        }
        if copiedBytes != file.size {
            // The camera was still writing it, or the card lied about the size.
            // The copy is internally consistent with its own hash, so it is
            // kept and verified — but the card is not safe to wipe.
            sourceFailures.append("\(file.relativePath) (size changed during "
                + "copy: \(file.size) -> \(copiedBytes) bytes)")
        }
        let hash = hasher.finalize()
        for target in open where target.isAlive {
            target.verify(file, expecting: hash, copiedBytes: copiedBytes,
                          algorithm: plan.algorithm, chunkBytes: plan.chunkBytes,
                          didWriteCopy: plan.didWriteCopy)
        }
    }

    /// One chunk to every destination at once. With a single destination the
    /// dispatch would be pure overhead, so that case writes inline.
    private func fanOut(_ chunk: UnsafeRawBufferPointer, to open: [OffloadTarget]) {
        guard open.count > 1 else {
            open.first?.write(chunk)
            return
        }
        let batch = OffloadChunkBatch(bytes: chunk, targets: open)
        DispatchQueue.concurrentPerform(iterations: open.count) { index in
            batch.targets[index].write(batch.bytes)
        }
    }

    // MARK: - progress

    /// Publishing on every chunk would flood the main thread on a card full of
    /// small files; five times a second is smooth and free. File boundaries are
    /// always published — that is when the numbers people watch change.
    private func report(force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastPublished) >= 0.2 else { return }
        lastPublished = now
        publish(OffloadProgress(
            filesTotal: files.count, bytesTotal: bytesTotal,
            currentFile: currentFile,
            destinations: targets.map {
                OffloadDestinationProgress(
                    id: $0.index, url: $0.root, filesDone: $0.filesDone,
                    bytesWritten: $0.bytesWritten,
                    bytesReused: $0.bytesReused,
                    mismatches: $0.mismatches.count, failure: $0.failure,
                    megabytesPerSecond: OffloadMetrics.megabytesPerSecond(
                        bytes: $0.bytesWritten, seconds: $0.elapsed))
            },
            elapsed: now.timeIntervalSince(started),
            isCancelling: cancellation.isCancelled))
    }

    // MARK: - the three report files

    /// Write the manifest, the summary and the picture, and fold what happened
    /// into the result. The order is the order they depend on each other in: the
    /// manifest first, so a manifest that could not be written is already part
    /// of the verdict the summary states, and the picture last, because it draws
    /// that same verdict.
    ///
    /// **Where the three land, which is not a free choice** (owner item 24):
    ///
    /// - the RECEIPT — the summary `.txt` and the report-card `.png` — goes in
    ///   the ROOT of the copy, `target.root`, alongside the footage. It is read
    ///   by a person, and it is the first thing in the folder they open rather
    ///   than something to go looking for in a subfolder of its own;
    /// - the MANIFEST goes in `ascmhl/`, and that one is not ours to move. The
    ///   ASC MHL v2 hashlist document puts it there, and `ascmhl`, Silverstack
    ///   and OffShoot look there and nowhere else — a manifest in the root
    ///   would simply not be found by the tools the whole file exists for.
    private func finalize(_ target: OffloadTarget,
                          run: OffloadRunFacts) -> OffloadDestinationResult {
        let stamp = Date()
        var result = OffloadDestinationResult(
            id: target.index, url: target.root,
            totals: OffloadDestinationTotals(
                filesVerified: target.verifiedCount, filesTotal: files.count,
                bytesWritten: target.bytesWritten, elapsed: target.elapsed),
            mismatches: target.mismatches, failure: target.failure,
            wasCancelled: stoppedShort, resume: target.resumeFacts)
        do {
            let manifest = try OffloadMHL.write(
                entries: target.entries, into: target.root,
                algorithm: plan.algorithm, creator: plan.creator, date: stamp)
            result.manifestURL = manifest
            // Which card that generation came from, so a run interrupted by a
            // lost disk can be resumed and a run of a DIFFERENT card into this
            // folder cannot be mistaken for one. Best-effort on purpose: a stamp
            // that could not be written costs a later run its shortcut, which is
            // the safe direction — it copies everything instead.
            _ = try? OffloadResume.stamp(identity, manifest: manifest,
                                         into: target.root)
        } catch {
            // "A vanished destination must not report offload done": an offload
            // without its manifest is not a verified offload, whatever the
            // copies looked like on the way past.
            result.failure = result.failure
                ?? "manifest: \(error.localizedDescription)"
        }
        do {
            result.summaryURL = try OffloadSummary.write(
                result: result, run: run, into: target.root, date: stamp,
                labels: plan.reportLabels)
        } catch {
            result.failure = result.failure
                ?? "summary: \(error.localizedDescription)"
        }
        // The picture is the copy of the report that gets handed over, and it
        // is the ONE artifact here that nothing depends on: the .txt beside it
        // states every fact it draws, and the manifest is what post re-verifies
        // against. Failing an otherwise-verified destination because a bitmap
        // context could not be made would be the worse lie, so this one is
        // allowed to be missing — which is why it is `try?` and the two above
        // are not.
        result.imageURL = try? OffloadReportCard.write(
            result: result, run: run, into: target.root, date: stamp,
            labels: plan.reportLabels)
        return result
    }

    /// The run-level facts, which are also everything the summary writer needs
    /// — it is handed these rather than the report, because the report is a
    /// list of the summaries it has not written yet.
    private func runFacts(finished: Date) -> OffloadRunFacts {
        OffloadRunFacts(
            source: plan.source, algorithm: plan.algorithm,
            creator: plan.creator,
            span: OffloadSpan(started: started, finished: finished),
            card: OffloadVolume(files: files.count, bytes: bytesTotal),
            problems: OffloadProblems(scan: scanFailures,
                                      source: sourceFailures))
    }
}

/// What crosses into the parallel writes, and why it is safe to send.
///
/// `concurrentPerform` takes a `@Sendable` closure, and neither a borrowed byte
/// buffer nor a destination is Sendable on its own. Both are safe here for
/// reasons the compiler cannot see, so the reasons are stated once, in a type,
/// rather than scattered as suppressions at the call site:
///
/// - the buffer belongs to the read loop, which does not touch it again until
///   `concurrentPerform` has joined every writer, and the writers only read it;
/// - iteration *i* touches `targets[i]` and nothing else, and the array itself
///   is never mutated while a write is in flight.
private struct OffloadChunkBatch: @unchecked Sendable {
    let bytes: UnsafeRawBufferPointer
    let targets: [OffloadTarget]
}
