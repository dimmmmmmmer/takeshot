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
/// relaunch, thumbnails, and the metadata log.
///
/// Split out of CaptureController: the type had grown past 2600 lines, the
/// size at which nobody reads it top to bottom any more.
extension CaptureController {
    func flashNewItem(_ url: URL) {
        recentlyAddedURL = url
        recentHighlightTask?.cancel()
        recentHighlightTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.recentlyAddedURL = nil
        }
    }
    /// Move a take to the Trash and drop it from the session.
    func deleteTake(_ take: Take) {
        do {
            try FileManager.default.trashItem(at: take.url, resultingItemURL: nil)
        } catch {
            lastError = "Delete: \(error.localizedDescription)"
            return
        }
        if playbackURL == take.url {
            player.pause()
            player.replaceCurrentItem(with: nil)
            playbackTap.detach()
            playbackURL = nil
        }
        if compareClipURL == take.url { compareClipURL = nil }
        takes.removeAll { $0.id == take.id }
        thumbnails[take.id] = nil
        scannedPaths.remove(take.url.path)
        exportTakeLog()
    }
    /// Move an Other-content file to the Trash.
    func deleteOtherFile(_ url: URL) {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            lastError = "Delete: \(error.localizedDescription)"
            return
        }
        if playbackURL == url {
            player.pause()
            player.replaceCurrentItem(with: nil)
            playbackTap.detach()
            rawPlayer?.pause()
            rawPlayer = nil
            playbackURL = nil
        }
        if compareClipURL == url { compareClipURL = nil }
        otherFiles.removeAll { $0 == url }
        otherThumbnails[url] = nil
        otherDurations[url] = nil
        scannedPaths.remove(url.path)
    }
    /// Recompute the taken-name warning for the NEXT take.
    /// Not shown while recording: the file being written naturally exists.
    func refreshNameCollision() {
        guard !isRecording else { nameCollision = nil; return }
        let engine = NamingEngine(template: settings.namingTemplate)
        let context = NamingContext(
            project: settings.projectName, date: Date(),
            take: nextTakeNumber, reel: roll, camera: settings.cameraLabel,
            postfix: settings.postfix ?? "",
            clipPadding: settings.clipPadWidthEffective,
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
        // files removed from the folder leave the panel, but NOT the shift log:
        // the normal way a day ends is the DIT moving the takes into the archive
        // structure, and rewriting the CSV from the shrunken list turned that
        // safe-looking move into the destruction of every rating, comment and
        // marker of the day
        let gone = takes.filter { !FileManager.default.fileExists(atPath: $0.url.path) }
        if !gone.isEmpty {
            let goneIDs = Set(gone.map(\.id))
            takes.removeAll { goneIDs.contains($0.id) }
            for take in gone {
                thumbnails[take.id] = nil
                scannedPaths.remove(take.url.path)
            }
            retiredTakes.append(contentsOf: gone)
        }
        var restored: [Take] = []
        var foreign: [URL] = []
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

        for url in candidates {
            if scannedPaths.contains(url.path) {
                if !takes.contains(where: { $0.url.path == url.path }) {
                    foreign.append(url)
                }
                continue
            }
            let ext = url.pathExtension.lowercased()
            guard ext == "mov" || ext == "mp4",
                  !Self.isCinemaDNGFolder(url) else {
                scannedPaths.insert(url.path)
                foreign.append(url)
                continue
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
                foreign.append(url)
                continue
            }
            let duration = (try? await asset.load(.duration))?.seconds ?? 0
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?
                .creationDate ?? Date.distantPast
            let startTC = await TimecodeReader.startTimecode(of: asset)
            let take = Take(
                url: url,
                displayName: url.deletingPathExtension().lastPathComponent,
                scene: "",
                roll: await value(TakeWriter.rollKey) ?? "",
                takeNumber: Int(await value(TakeWriter.clipKey) ?? "") ?? 0,
                startTimecode: startTC,
                durationSeconds: duration,
                rating: meta[url.lastPathComponent]?.rating ?? .none,
                comment: meta[url.lastPathComponent]?.comment ?? "",
                recordedAt: created,
                markers: markers[url.lastPathComponent] ?? [])
            restored.append(take)
        }

        if !restored.isEmpty {
            let known = Set(takes.map { $0.url.path })
            let new = restored.filter { !known.contains($0.url.path) }
            if !new.isEmpty {
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
        }
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
        }
        let sorted = foreign.sorted { modified($0) > modified($1) }
        if otherFiles != sorted {
            otherFiles = sorted
            // thumbnails load lazily per cell; prune caches for files that left
            let current = Set(sorted)
            otherThumbnails = otherThumbnails.filter { current.contains($0.key) }
            otherDurations = otherDurations.filter { current.contains($0.key) }
        }
        // a file may have appeared in the folder externally — refresh the taken-name warning
        refreshNameCollision()
    }
    /// The next clip number — after the max in the current roll.
    func continueClipNumbering() {
        let maxClip = takes.filter { $0.roll == roll }.map(\.takeNumber).max() ?? 0
        nextTakeNumber = maxClip + 1
    }
    /// Thumbnails for Other content: photos directly, videos via a frame generator.
    private func generateOtherThumbnails(for urls: [URL]) {
        let missing = urls.filter { otherThumbnails[$0] == nil }
        guard !missing.isEmpty else { return }
        Task.detached(priority: .utility) { [weak self] in
            for url in missing {
                var image: NSImage?
                let ext = url.pathExtension.lowercased()
                if Self.imageExtensions.contains(ext) {
                    // thumbnail-sized decode: a full 24 MP still would pin
                    // ~100 MB in the cache
                    if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                       let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                           kCGImageSourceCreateThumbnailFromImageAlways: true,
                           kCGImageSourceThumbnailMaxPixelSize: 256,
                       ] as CFDictionary) {
                        image = NSImage(cgImage: cg,
                                        size: NSSize(width: cg.width,
                                                     height: cg.height))
                    }
                } else if Self.isCinemaDNGFolder(url) {
                    let frames = DNGSequenceSource.frameURLs(in: url)
                    if let middle = frames.dropFirst(frames.count / 2).first,
                       let src = CGImageSourceCreateWithURL(middle as CFURL, nil),
                       let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                           kCGImageSourceCreateThumbnailFromImageAlways: true,
                           kCGImageSourceThumbnailMaxPixelSize: 256,
                       ] as CFDictionary) {
                        image = NSImage(cgImage: cg,
                                        size: NSSize(width: cg.width,
                                                     height: cg.height))
                    }
                    await MainActor.run { [weak self] in
                        self?.otherDurations[url] = Double(frames.count) / 24.0
                    }
                } else if ext == "braw" {
                    if let clip = try? CBRClip(path: url.path) {
                        if clip.frameCount > 0,
                           let buffer = clip.copyFrame(at: clip.frameCount / 2) {
                            image = Self.thumbnail(from: buffer, maxSize: 256)
                        }
                        if clip.frameRate > 0 {
                            let seconds = Double(clip.frameCount)
                                / Double(clip.frameRate)
                            await MainActor.run { [weak self] in
                                self?.otherDurations[url] = seconds
                            }
                        }
                    }
                } else {
                    let asset = AVURLAsset(url: url)
                    let generator = AVAssetImageGenerator(asset: asset)
                    generator.appliesPreferredTrackTransform = true
                    generator.maximumSize = CGSize(width: 256, height: 256)
                    if let (cgImage, _) = try? await generator.image(
                        at: CMTime(seconds: 0.5, preferredTimescale: 600)) {
                        image = NSImage(cgImage: cgImage,
                                        size: NSSize(width: cgImage.width,
                                                     height: cgImage.height))
                    }
                    if let duration = try? await asset.load(.duration) {
                        let seconds = duration.seconds
                        await MainActor.run { [weak self] in
                            self?.otherDurations[url] = seconds
                        }
                    }
                }
                if let image {
                    let boxed = UncheckedSendable(image) // NSImage predates Sendable
                    await MainActor.run { [weak self] in
                        self?.otherThumbnails[url] = boxed.value
                        self?.otherThumbsInFlight.remove(url)
                    }
                }
            }
        }
    }
    nonisolated private static func thumbnail(from buffer: CVPixelBuffer,
                                              maxSize: CGFloat) -> NSImage? {
        let image = CIImage(cvPixelBuffer: buffer)
        let scale = min(1, maxSize / max(image.extent.width, image.extent.height))
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let cg = context.createCGImage(scaled, from: scaled.extent)
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
    nonisolated private static func findForeignVideos(
        root: URL, excluding ownPaths: Set<String>) -> (files: [URL], busy: Bool) {
        var found: [URL] = []
        var busy = false
        let cutoff = Date().addingTimeInterval(-3) // don't touch files still being written
        if let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let url as URL in enumerator {
                // a CinemaDNG folder is one clip: list it, skip the frames
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?
                    .isDirectory == true {
                    if !DNGSequenceSource.frameURLs(in: url).isEmpty {
                        enumerator.skipDescendants()
                        found.append(url)
                    }
                    continue
                }
                let ext = url.pathExtension.lowercased()
                let isVideo = videoExtensions.contains(ext)
                guard isVideo || imageExtensions.contains(ext),
                      !ownPaths.contains(url.path) else { continue }
                // only videos wait out the write: image writes are single atomic
                // calls, and a freshly grabbed still must show up immediately
                if isVideo {
                    let modified = (try? url.resourceValues(
                        forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    if let modified, modified > cutoff {
                        busy = true
                        continue
                    }
                }
                found.append(url)
            }
        }
        return (found.sorted { $0.lastPathComponent < $1.lastPathComponent }, busy)
    }
    /// Resolve-compatible CSV: rewritten on every take and every circle-take mark
    /// — in Resolve it's imported via Media Pool → Import Metadata.
    func exportTakeLog() {
        let takes = (takes + retiredTakes).sorted { $0.recordedAt < $1.recordedAt }
        let root = destinationRoot
        Self.takeLogQueue.async { [weak self] in
            do {
                _ = try TakeLogExporter.write(takes: takes, toDirectory: root)
                _ = try TakeLogExporter.writeMarkers(takes: takes,
                                                     toDirectory: root)
            } catch {
                // ratings/comments silently not persisting is a day-loss bug
                DispatchQueue.main.async {
                    self?.lastError = "Metadata log NOT saved: "
                        + error.localizedDescription
                }
            }
        }
    }
    /// Grid cells ask for thumbnails as they appear — decoding every take
    /// eagerly pinned 100+ MB of images the list mode never shows.
    func requestThumbnail(for take: Take) {
        guard thumbnails[take.id] == nil,
              !thumbnailsInFlight.contains(take.id) else { return }
        thumbnailsInFlight.insert(take.id)
        generateThumbnail(for: take)
    }
    func requestOtherThumbnail(for url: URL) {
        guard otherThumbnails[url] == nil,
              !otherThumbsInFlight.contains(url) else { return }
        otherThumbsInFlight.insert(url)
        generateOtherThumbnails(for: [url])
    }
    private func storeThumbnail(_ image: NSImage, for id: Take.ID) {
        thumbnails[id] = image
        thumbnailLRU.removeAll { $0 == id }
        thumbnailLRU.append(id)
        while thumbnailLRU.count > Self.thumbnailCacheLimit {
            thumbnails[thumbnailLRU.removeFirst()] = nil
        }
    }
    /// A preview frame from the recorded file; the file finalizes asynchronously,
    /// so several attempts with a pause.
    private func generateThumbnail(for take: Take) {
        Task.detached(priority: .utility) { [weak self] in
            for _ in 0..<10 {
                if FileManager.default.fileExists(atPath: take.url.path) {
                    let asset = AVURLAsset(url: take.url)
                    let generator = AVAssetImageGenerator(asset: asset)
                    generator.appliesPreferredTrackTransform = true
                    generator.maximumSize = CGSize(width: 256, height: 256)
                    let time = CMTime(seconds: min(1.0, take.durationSeconds / 2),
                                      preferredTimescale: 600)
                    if let (cgImage, _) = try? await generator.image(at: time) {
                        // NSImage predates Sendable; the box states the contract
                        // (built here, handed over once, used only on main)
                        let image = UncheckedSendable(NSImage(
                            cgImage: cgImage,
                            size: NSSize(width: cgImage.width,
                                         height: cgImage.height)))
                        await MainActor.run { [weak self] in
                            self?.storeThumbnail(image.value, for: take.id)
                            self?.thumbnailsInFlight.remove(take.id)
                        }
                        return
                    }
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            // every attempt failed: clear the in-flight mark or this take can
            // never be retried for the rest of the session
            await MainActor.run { [weak self] in
                _ = self?.thumbnailsInFlight.remove(take.id)
            }
        }
    }
}
