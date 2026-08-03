import CaptureCore
import Foundation

/// Walking the record folder, off the main actor.
///
/// Split out of `+LibraryScan`: everything here is `nonisolated` and runs on a
/// utility task, because a shift's folder is thousands of entries and stat-ing
/// them on the MainActor stalls the window while a take is recording.
extension CaptureController {
    /// What one entry in the record folder turned out to be.
    private enum ScanEntry {
        case clip          // playable, list it
        case clipReel      // a DNG folder: one clip, do not descend into it
        case stillWriting  // a video whose write has not settled — come back
        case ignore
    }

    nonisolated static func findForeignVideos(
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
        // An R3D clip past 4 GB is a hundred files that are all one clip — the
        // SDK opens the first part and pulls the rest in itself. Listing every
        // part would fill the panel with rows that open identical footage, and
        // the 3-second settle rule would keep the folder "busy" for the whole
        // duration of a card copy because some part of it was always fresh.
        if R3DSource.isContinuationPart(url) { return .ignore }
        // only videos wait out the write: image writes are single atomic
        // calls, and a freshly grabbed still must show up immediately
        guard isVideo else { return .clip }
        let modified = (try? url.resourceValues(
            forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let modified, modified > cutoff { return .stillWriting }
        return .clip
    }
}
