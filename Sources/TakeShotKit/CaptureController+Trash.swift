import CaptureCore
import Foundation

/// Moving items out of the panel and into the Trash.
///
/// Split out of `+Takes`. A take and a foreign file leave the session in
/// exactly the same way — the difference is only which list they came out of —
/// so the release itself is written once here.
extension CaptureController {
    /// Move everything selected to the Trash.
    ///
    /// Each item goes through the single-item path it would go through on its
    /// own — `deleteTake` / `deleteOtherFile` — so a trashed take leaves the
    /// metadata log, the player, the sync-play grid and the compare slot exactly
    /// as it always has, and one that fails to move stays selected for the
    /// operator to retry.
    @discardableResult
    func trashSelection() -> Int {
        var trashed = 0
        for url in selectedInOrder {
            if let take = takes.first(where: { $0.url == url }) {
                let before = takes.count
                deleteTake(take)
                if takes.count < before { trashed += 1 }
            } else {
                let before = otherFiles.count
                deleteOtherFile(url)
                if otherFiles.count < before { trashed += 1 }
            }
        }
        if trashed > 0 { lastNotice = L("trash_done", localizedItemCount(trashed)) }
        return trashed
    }

    /// Move a take to the Trash and drop it from the session.
    func deleteTake(_ take: Take) {
        guard trashAndRelease(take.url) else { return }
        takes.removeAll { $0.id == take.id }
        thumbnails[take.id] = nil
        exportTakeLog()
    }

    /// Move an Other-content file to the Trash.
    func deleteOtherFile(_ url: URL) {
        guard trashAndRelease(url) else { return }
        otherFiles.removeAll { $0 == url }
        otherThumbnails[url] = nil
        otherDurations[url] = nil
        otherPixelSizes[url] = nil
        // A deliberate trash takes the clip's markers with it, exactly as
        // `transport.forgetClip` above takes its in/out points. This is NOT the
        // case a file merely leaving the folder is (the DIT moving footage to
        // the archive): that one keeps its rows, like a retired take.
        guard otherMarkers.removeValue(
            forKey: Self.markerKey(url)) != nil else { return }
        exportTakeLog()
    }

    /// Move one file to the Trash and let go of every reference the session
    /// still holds to it. `false` means the move failed, the file is still
    /// there, and the caller must leave its own bookkeeping alone.
    ///
    /// Takes and Other content walked separate copies of this, and the copies
    /// had drifted: only the Other-content one tore down the RAW engine, so a
    /// RAW clip adopted as a take would have been left decoding a file that no
    /// longer exists. Nothing produces such a take today (the scan only adopts
    /// .mov/.mp4), which is why nobody had met it.
    ///
    /// **The sync-play grid is on that list, and it was the one holder missing
    /// from it.** Every other reference is released by name here — the
    /// selection, the in/out table, the single player, the RAW engine, the
    /// compare slot — but a grid holds 2–4 files open in tiles of its own, and
    /// `playbackURL` names none of them. The reachable case is not exotic, it
    /// is the workflow: a grid is built FROM the selection, and `trashSelection`
    /// walks that same selection — so comparing four takes and trashing the
    /// three that failed left the grid decoding, showing and transport-locking
    /// files that were now in the Trash, out of the take list, and gone from the
    /// CSV. The whole session goes rather than the one tile: the schedule is
    /// built from the sources it opened with, and two takes is the floor a grid
    /// exists at, so there is no grid left to re-align around a gap.
    private func trashAndRelease(_ url: URL) -> Bool {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            lastError = L("toast_delete_failed", error.localizedDescription)
            return false
        }
        dropFromSelection([url])
        transport.forgetClip(url)
        if syncPlayShows(url) { endSyncPlay() }
        if playbackURL == url {
            player.pause()
            player.replaceCurrentItem(with: nil)
            playbackTap.detach()
            rawPlayer?.pause()
            rawPlayer = nil
            playbackURL = nil
        }
        if compareClipURL == url { compareClipURL = nil }
        scannedPaths.remove(url.path)
        return true
    }
}
