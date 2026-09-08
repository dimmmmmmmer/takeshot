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

    /// `skipping` names folders this app WRITES INTO, and the walk does not
    /// descend into them.
    ///
    /// Foreign content means content this app did not put there. Dailies land
    /// in `<record folder>/Dailies` by default, so every transcode the operator
    /// asked for came back as somebody else's file (owner: "dailies добавляются
    /// as other content"). An offload destination is the same rule with a
    /// sharper edge: a card copied into the record folder is a hundred thousand
    /// files, and the panel would list every one of them.
    nonisolated static func findForeignVideos(
        root: URL, excluding ownPaths: Set<String>,
        skipping ourFolders: Set<String> = []) -> (files: [URL], busy: Bool) {
        var found: [URL] = []
        var busy = false
        let cutoff = Date().addingTimeInterval(-3) // don't touch files still being written
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return ([], false) }

        for case let url as URL in enumerator {
            // **Resolved on both sides, and matched by PREFIX.** Two traps
            // here, and each one silently skips nothing. `/var/folders/…` and
            // `/private/var/folders/…` are the same folder spelled two ways —
            // `standardizedFileURL` prefers one and `resolvingSymlinksInPath`
            // the other, so a comparison that mixes them never matches. And a
            // directory enumerator is not required to hand back the directory
            // itself before its contents, so a rule that only recognises the
            // folder can miss everything inside it. Asking whether each path
            // is UNDER one of ours cannot be defeated by either.
            if !ourFolders.isEmpty, isOurs(url, folders: ourFolders) {
                enumerator.skipDescendants()
                continue
            }
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

    /// Whether `url` is one of our folders or anything inside one.
    ///
    /// **Both sides go through `standardizedFileURL`, and that is the only
    /// thing that makes the comparison work.** `/var/folders/…` and
    /// `/private/var/folders/…` name the same place, and on a path that EXISTS
    /// this is what folds them onto one spelling (measured: both forms of the
    /// temp directory come back as `/var/…`). On a path that does not exist
    /// neither this nor `resolvingSymlinksInPath` changes anything — which is
    /// fine here, because the folders being compared are folders that are
    /// there.
    ///
    /// Matched by PREFIX rather than equality: a directory enumerator is not
    /// required to hand back a directory before its contents, so a rule that
    /// only recognised the folder itself could miss everything inside it.
    nonisolated static func isOurs(_ url: URL, folders: Set<String>) -> Bool {
        let path = url.standardizedFileURL.path
        return folders.contains { path == $0 || path.hasPrefix($0 + "/") }
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
