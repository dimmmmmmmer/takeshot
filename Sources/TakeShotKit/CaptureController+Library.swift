import AVFoundation
import AppKit
import CaptureCore
import Foundation
import SwiftUI
import os.log

/// The record folder itself: choosing it, watching it, and the taken-name
/// warning for the take about to be recorded.
///
/// Split out of CaptureController: the type had grown past 2600 lines, the
/// size at which nobody reads it top to bottom any more. The scan that turns
/// the folder into a library is `+LibraryScan`, deciding what a file it found
/// IS is `+LibraryRestore`, walking the tree off the actor is `+LibraryWalk`,
/// editing what the scan found lives in `+Takes`, decoding previews of it in
/// `+Thumbnails`.
extension CaptureController {
    nonisolated static let videoExtensions: Set<String> =
        ["mov", "mp4", "mxf", "m4v", "avi", "braw", "r3d"]
    nonisolated static let imageExtensions: Set<String> =
        ["jpg", "jpeg", "png", "heic", "tif", "tiff", "dng", "arw", "cr2", "webp"]

    /// Recompute the taken-name warning for the NEXT take.
    /// Not shown while recording: the file being written naturally exists.
    func refreshNameCollision() {
        guard !isRecording else { nameCollision = nil; return }
        let url = destinationRoot
            .appendingPathComponent(pendingTakeName)
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
        otherPixelSizes.removeAll()
        // a new folder has its own markers sidecar; keeping the old folder's
        // rows would write them into it on the next edit
        otherMarkers.removeAll()
        scannedPaths.removeAll()
        selectedItems.removeAll()
        selectionAnchor = nil
        transport.forgetAllClips() // a new folder is a different set of clips
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
}
