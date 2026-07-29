import AVFoundation
import AppKit
import CaptureCore
import CBraw
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import SwiftUI
import os.log

/// The record folder as a library: scanning it, restoring takes across a
/// relaunch, and the taken-name warning.
///
/// Split out of CaptureController: the type had grown past 2600 lines, the
/// size at which nobody reads it top to bottom any more. Editing what the scan
/// found lives in `+Takes`, decoding previews of it in `+Thumbnails`.
extension CaptureController {
    nonisolated static let videoExtensions: Set<String> =
        ["mov", "mp4", "mxf", "m4v", "avi", "braw", "r3d"]
    nonisolated static let imageExtensions: Set<String> =
        ["jpg", "jpeg", "png", "heic", "tif", "tiff", "dng", "arw", "cr2", "webp"]

    /// Recompute the taken-name warning for the NEXT take.
    /// Not shown while recording: the file being written naturally exists.
    func refreshNameCollision() {
        guard !isRecording else { nameCollision = nil; return }
        let engine = NamingEngine(template: settings.namingTemplate,
                                  clipPadding: settings.clipPadWidthEffective)
        let context = NamingContext(
            project: settings.projectName, date: Date(),
            take: nextTakeNumber, reel: roll, camera: settings.cameraLabel,
            postfix: settings.postfix ?? "",
            timecode: currentTimecode)
        let url = destinationRoot
            .appendingPathComponent(engine.fileName(for: context))
            .appendingPathExtension("mov")
        nameCollision = FileManager.default.fileExists(atPath: url.path)
            ? url.lastPathComponent : nil
    }
    /// New record folder: old takes/files don't apply — clear and rescan.
    func resetLibraryForNewDestination() {
        libraryGeneration += 1 // invalidate a scan already walking the old folder
        takes.removeAll()
        retiredTakes.removeAll() // a new folder gets its own log
        otherFiles.removeAll()
        thumbnails.removeAll()
        otherThumbnails.removeAll()
        otherDurations.removeAll()
        scannedPaths.removeAll()
        nextTakeNumber = 1
        scanDestinationFolder()
    }
    func openDestinationInFinder() {
        try? FileManager.default.createDirectory(at: destinationRoot,
                                                 withIntermediateDirectories: true)
        NSWorkspace.shared.open(destinationRoot)
    }
    /// Change-record-folder dialog (used from both Settings and the bottom bar).
    func chooseDestinationFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = destinationRoot
        if panel.runModal() == .OK, let url = panel.url {
            settings.destinationPath = url.path
        }
    }
    /// Light polling of the record folder: video files not among our takes
    /// are shown in a separate Other content block.
    func startFolderSync() {
        startFolderWatcher()
        Task { [weak self] in
            while let self, !Task.isCancelled {
                self.scanDestinationFolder()
                // the kernel watcher is the primary trigger; this is a safety net
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }
    /// Kernel notifications on the record folder: add/delete shows up right away
    /// (the 5 s poll stays as a safety net for metadata-only changes).
    func startFolderWatcher() {
        folderWatcher?.cancel() // its cancel handler closes the old fd
        folderWatcher = nil
        try? FileManager.default.createDirectory(at: destinationRoot,
                                                 withIntermediateDirectories: true)
        let fd = open(destinationRoot.path, O_EVTONLY)
        guard fd >= 0 else {
            os_log("folder watcher FAILED to arm: %{public}s",
                   log: CapturePipeline.levelsLog, type: .error, destinationRoot.path)
            return
        }
        os_log("folder watcher armed: %{public}s",
               log: CapturePipeline.levelsLog, type: .default, destinationRoot.path)
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete],
            queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                // the fd now points at an unlinked inode — the watcher is dead
                // and an open take is writing into an orphan; recreate + rearm
                try? FileManager.default.createDirectory(
                    at: self.destinationRoot, withIntermediateDirectories: true)
                self.lastError = "Record folder was moved/deleted — recreated"
                self.startFolderWatcher()
                return
            }
            guard !self.folderRescanScheduled else { return }
            // debounce bursts (a recording take touches the folder every frame)
            self.folderRescanScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return }
                self.folderRescanScheduled = false
                os_log("folder event -> rescan", log: CapturePipeline.levelsLog,
                       type: .default)
                self.scanDestinationFolder()
            }
        }
        source.setCancelHandler { [fd] in close(fd) }
        source.resume()
        folderWatcher = source
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
        // a file may have appeared in the folder externally — refresh the taken-name warning
        refreshNameCollision()
    }
    /// What a scanned file turned out to be.
    private enum ScanOutcome {
        case take(Take)  // ours: the tag is there and the metadata was read
        case foreign     // someone else's file — Other content
        case known       // already in the takes list; nothing to do
    }
    /// Ratings, comments and markers of the day, as saved next to the takes.
    private func loadStoredMetadata()
        -> (meta: [String: TakeLogExporter.TakeMeta],
            markers: [String: [TakeMarker]]) {
        // Lossy decode on purpose: one bad byte must not wipe the day's
        // ratings. The failable String(bytes:encoding:) the linter prefers
        // would return nil for the whole file, which is exactly the outcome
        // this guards against.
        // swiftlint:disable optional_data_string_conversion
        let meta = (try? Data(contentsOf: takeLogURL))
            .map { TakeLogExporter.parseMetadata(
                csv: String(decoding: $0, as: UTF8.self)) } ?? [:]
        let markersURL = destinationRoot
            .appendingPathComponent(TakeLogExporter.markersFileName)
        let markers = (try? Data(contentsOf: markersURL))
            .map { TakeLogExporter.parseMarkers(
                csv: String(decoding: $0, as: UTF8.self)) } ?? [:]
        // swiftlint:enable optional_data_string_conversion
        return (meta, markers)
    }
    /// Identify one candidate, restoring its take metadata when it is ours.
    private func classify(
        _ url: URL,
        stored: (meta: [String: TakeLogExporter.TakeMeta],
                 markers: [String: [TakeMarker]])) async -> ScanOutcome {
        if scannedPaths.contains(url.path) {
            return takes.contains(where: { $0.url.path == url.path })
                ? .known : .foreign
        }
        let ext = url.pathExtension.lowercased()
        guard ext == "mov" || ext == "mp4",
              !Self.isCinemaDNGFolder(url) else {
            scannedPaths.insert(url.path)
            return .foreign
        }
        let asset = AVURLAsset(url: url)
        let metadata = (try? await asset.load(.metadata)) ?? []
        func value(_ key: String) async -> String? {
            guard let item = metadata.first(where: { ($0.key as? String) == key })
            else { return nil }
            return try? await item.load(.stringValue)
        }
        scannedPaths.insert(url.path)
        guard await value(TakeWriter.markerKey) != nil else {
            return .foreign
        }
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?
            .creationDate ?? Date.distantPast
        let startTC = await TimecodeReader.startTimecode(of: asset)
        let name = url.lastPathComponent
        var take = Take(
            url: url,
            scene: "",
            roll: await value(TakeWriter.rollKey) ?? "",
            takeNumber: Int(await value(TakeWriter.clipKey) ?? "") ?? 0,
            startTimecode: startTC,
            durationSeconds: duration,
            recordedAt: created)
        // the operator's own work, restored from the sidecars rather than read
        // off the file
        take.rating = stored.meta[name]?.rating ?? .none
        take.comment = stored.meta[name]?.comment ?? ""
        take.markers = stored.markers[name] ?? []
        return .take(take)
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
    /// The next clip number — after the max in the current roll.
    func continueClipNumbering() {
        let maxClip = takes.filter { $0.roll == roll }.map(\.takeNumber).max() ?? 0
        nextTakeNumber = maxClip + 1
    }
    /// What one entry in the record folder turned out to be.
    private enum ScanEntry {
        case clip          // playable, list it
        case clipReel      // a DNG folder: one clip, do not descend into it
        case stillWriting  // a video whose write has not settled — come back
        case ignore
    }

    nonisolated private static func findForeignVideos(
        root: URL, excluding ownPaths: Set<String>) -> (files: [URL], busy: Bool) {
        var found: [URL] = []
        var busy = false
        let cutoff = Date().addingTimeInterval(-3) // don't touch files still being written
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return ([], false) }

        for case let url as URL in enumerator {
            switch classify(url, excluding: ownPaths, settledBefore: cutoff) {
            case .clip:
                found.append(url)
            case .clipReel:
                enumerator.skipDescendants()
                found.append(url)
            case .stillWriting:
                busy = true
            case .ignore:
                break
            }
        }
        return (found.sorted { $0.lastPathComponent < $1.lastPathComponent }, busy)
    }

    nonisolated private static func classify(
        _ url: URL, excluding ownPaths: Set<String>,
        settledBefore cutoff: Date) -> ScanEntry {
        // a CinemaDNG folder is one clip, not thousands of frames
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            return DNGSequenceSource.frameURLs(in: url).isEmpty ? .ignore : .clipReel
        }
        let ext = url.pathExtension.lowercased()
        let isVideo = videoExtensions.contains(ext)
        guard isVideo || imageExtensions.contains(ext),
              !ownPaths.contains(url.path) else { return .ignore }
        // only videos wait out the write: image writes are single atomic
        // calls, and a freshly grabbed still must show up immediately
        guard isVideo else { return .clip }
        let modified = (try? url.resourceValues(
            forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let modified, modified > cutoff { return .stillWriting }
        return .clip
    }
}
