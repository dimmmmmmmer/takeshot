import AVFoundation
import CaptureCore
import Foundation

/// One pass over the record folder, and what it does to the lists the panel
/// shows.
///
/// Split out of `+Library`, which had grown to hold the folder itself, the
/// scan, the classification and the off-actor walk at once. This half is the
/// pass: guarding it against overlapping itself, and adopting, retiring or
/// publishing what came back.
extension CaptureController {
    /// What a scanned file turned out to be. Read here and decided in
    /// `+LibraryRestore`.
    enum ScanOutcome {
        case take(Take)  // ours: the tag is there and the metadata was read
        case foreign     // someone else's file — Other content
        case known       // already in the takes list; nothing to do
    }

    func scanDestinationFolder() {
        guard !scanInFlight else {
            // classifyFoundFiles suspends on metadata loads, and the MainActor
            // runs other work at every suspension point — including another
            // scan. Overlapping runs interleaved their results: the same file
            // ended up in the takes list and in Other content at once.
            rescanWhenIdle = true
            return
        }
        scanInFlight = true
        let root = destinationRoot
        let generation = libraryGeneration
        let ownTakePaths = Set(takes.map { $0.url.path })
        Task.detached(priority: .utility) { [weak self] in
            let (candidates, busy) = Self.findForeignVideos(root: root,
                                                            excluding: ownTakePaths)
            await self?.finishScan(candidates, rescanSoon: busy,
                                   generation: generation)
        }
    }
    private func finishScan(_ candidates: [URL], rescanSoon: Bool,
                            generation: Int) async {
        defer {
            scanInFlight = false
            if rescanWhenIdle {
                rescanWhenIdle = false
                scanDestinationFolder()
            }
        }
        guard generation == libraryGeneration else { return }
        await classifyFoundFiles(candidates, rescanSoon: rescanSoon)
    }
    /// Our files (the com.takeshot.origin QuickTime tag) return to the takes list
    /// after a restart; the rest are Other content.
    private func classifyFoundFiles(_ candidates: [URL],
                                    rescanSoon: Bool) async {
        // a file was skipped as "still being written" — nothing will re-trigger
        // the scan once the copy finishes, so come back for it ourselves
        if rescanSoon, !busyRescanScheduled {
            busyRescanScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self else { return }
                self.busyRescanScheduled = false
                self.scanDestinationFolder()
            }
        }
        retireMissingTakes()
        let stored = loadStoredMetadata()
        var restored: [Take] = []
        var foreign: [URL] = []
        for url in candidates {
            switch await classify(url, stored: stored) {
            case .take(let take): restored.append(take)
            case .foreign: foreign.append(url)
            case .known: continue
            }
        }
        adopt(restored)
        publish(foreign: foreign)
        // Markers flagged on a foreign clip in an earlier session come back with
        // it. Restricted to what this pass classified as foreign, so a row whose
        // file is one of our takes cannot be adopted here as well as on the take.
        restoreOtherMarkers(stored.markers,
                            forFilesNamed: Set(foreign.map(\.lastPathComponent)))
        // In/out marked on a clip in an earlier session comes back with the clip.
        // This is the restart path: on launch the first scan is what discovers the
        // day's clips, and it is the only moment at which their ranges are known
        // to belong to files that are really there.
        if !candidates.isEmpty {
            transport.restoreRanges(
                loadStoredRanges(),
                forFilesNamed: Set(candidates.map(\.lastPathComponent)))
        }
        // the DIT moving footage to the archive is the normal way an item leaves
        // the panel mid-shift; Delete must not then act on a stale selection
        pruneSelection()
        // a file may have appeared in the folder externally — refresh the taken-name warning
        refreshNameCollision()
    }
    /// Files removed from the folder leave the panel, but NOT the shift log:
    /// the normal way a day ends is the DIT moving the takes into the archive
    /// structure, and rewriting the CSV from the shrunken list turned that
    /// safe-looking move into the destruction of every rating, comment and
    /// marker of the day.
    private func retireMissingTakes() {
        let gone = takes.filter { !FileManager.default.fileExists(atPath: $0.url.path) }
        guard !gone.isEmpty else { return }
        let goneIDs = Set(gone.map(\.id))
        takes.removeAll { goneIDs.contains($0.id) }
        for take in gone {
            thumbnails[take.id] = nil
            scannedPaths.remove(take.url.path)
        }
        retiredTakes.append(contentsOf: gone)
    }
    /// Takes restored from the folder join the list (once).
    private func adopt(_ restored: [Take]) {
        guard !restored.isEmpty else { return }
        let known = Set(takes.map { $0.url.path })
        let new = restored.filter { !known.contains($0.url.path) }
        guard !new.isEmpty else { return }
        // a file that came back (volume remounted, take moved back) is
        // live again, so it must not also sit in the retired list
        let returned = Set(new.map { $0.url.path })
        retiredTakes.removeAll { returned.contains($0.url.path) }
        takes.append(contentsOf: new)
        takes.sort { $0.recordedAt < $1.recordedAt }
        // thumbnails load lazily as cells appear (restored sessions
        // used to decode hundreds of files at startup)
        continueClipNumbering()
    }
    /// Everything that isn't ours, newest first — the Other content block.
    private func publish(foreign: [URL]) {
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
        }
        let sorted = foreign.sorted { modified($0) > modified($1) }
        guard otherFiles != sorted else { return }
        otherFiles = sorted
        // thumbnails load lazily per cell; prune caches for files that left
        let current = Set(sorted)
        otherThumbnails = otherThumbnails.filter { current.contains($0.key) }
        otherDurations = otherDurations.filter { current.contains($0.key) }
    }
}
