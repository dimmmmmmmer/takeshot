import AVFoundation
import AppKit
import CaptureCore
import CoreMedia
import Foundation
import SwiftUI

/// The take list itself: ratings, comments, deletion, and the metadata log
/// that carries them off the shift.
///
/// Split out of CaptureController+Library: scanning the folder and editing
/// what was found are separate jobs.
extension CaptureController {
    /// CSV writes go through one serial queue — two detached writers could
    /// finish out of order and an older snapshot would overwrite a newer one.
    nonisolated static let takeLogQueue = DispatchQueue(
        label: "takeshot.takelog", qos: .utility)

    /// The metadata log URL (for "show in Finder").
    var takeLogURL: URL {
        destinationRoot.appendingPathComponent(TakeLogExporter.fileName)
    }

    /// Click the circle: none → good → bad → none.
    func cycleRating(_ take: Take) {
        guard let idx = takes.firstIndex(where: { $0.id == take.id }) else { return }
        switch takes[idx].rating {
        case .none: takes[idx].rating = .good
        case .good: takes[idx].rating = .bad
        case .bad: takes[idx].rating = .none
        }
        exportTakeLog()
    }

    func setRating(_ rating: TakeRating, for take: Take) {
        guard let idx = takes.firstIndex(where: { $0.id == take.id }) else { return }
        takes[idx].rating = rating
        exportTakeLog()
    }

    /// Hotkey: set/clear the last take's rating.
    func toggleLastRating(_ rating: TakeRating) {
        guard let last = takes.last else { return }
        setRating(last.rating == rating ? .none : rating, for: last)
    }

    /// Set a free-text comment on a take (persisted to the CSV Comments column).
    func setComment(_ comment: String, for take: Take) {
        guard let idx = takes.firstIndex(where: { $0.id == take.id }) else { return }
        guard takes[idx].comment != comment else { return }
        takes[idx].comment = comment
        exportTakeLog()
    }

    // MARK: - panel selection

    /// Every item in the panel, top to bottom: the takes as the list shows them
    /// (newest first), then Other content. This is the order a shift-click range
    /// spans and the order a Finder reveal hands over.
    var panelItemOrder: [URL] {
        takes.reversed().map(\.url) + otherFiles
    }

    /// The selection in the order it is shown.
    var selectedInOrder: [URL] {
        panelItemOrder.filter { selectedItems.contains($0) }
    }

    /// A click on a panel item with the keyboard as it stands.
    func clickPanelItem(_ url: URL, modifiers: NSEvent.ModifierFlags) {
        clickPanelItem(url, command: modifiers.contains(.command),
                       shift: modifiers.contains(.shift))
    }

    /// cmd toggles this one item, shift extends from the anchor, a plain click
    /// selects it alone.
    func clickPanelItem(_ url: URL, command: Bool = false, shift: Bool = false) {
        if command {
            if selectedItems.contains(url) {
                selectedItems.remove(url)
            } else {
                selectedItems.insert(url)
            }
            selectionAnchor = url
        } else if shift, let range = shiftRange(to: url) {
            // The anchor deliberately stays where it was, and the range is added
            // to the selection rather than replacing it. Sweeping up the day's
            // rejects is cmd-click a few, then shift-click a run: measuring every
            // shift-click from the same anchor keeps the run one range instead of
            // chaining a new one from each click, and adding rather than
            // replacing keeps the cmd-clicked items. A plain click is how the
            // selection is started over — so shift-clicking back towards the
            // anchor does not shrink what is already selected.
            selectedItems.formUnion(range)
        } else {
            selectedItems = [url]
            selectionAnchor = url
        }
    }

    /// The items between the anchor and `url` inclusive; nil when there is no
    /// anchor yet or either end has left the panel.
    private func shiftRange(to url: URL) -> [URL]? {
        let order = panelItemOrder
        guard let anchor = selectionAnchor,
              let from = order.firstIndex(of: anchor),
              let to = order.firstIndex(of: url) else { return nil }
        return Array(order[min(from, to)...max(from, to)])
    }

    /// What a panel action applies to when the operator acts on `url`: the whole
    /// selection when `url` is part of it (the Finder rule), otherwise just the
    /// item that was clicked.
    func panelActionTargets(for url: URL) -> [URL] {
        selectedItems.contains(url) ? selectedInOrder : [url]
    }

    /// Show the selection — or just the clicked item — in Finder.
    func revealInFinder(_ url: URL) {
        let targets = panelActionTargets(for: url)
        guard !targets.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(targets)
    }

    /// Move everything selected to the Trash.
    ///
    /// Each item goes through the single-item path it would go through on its
    /// own — `deleteTake` / `deleteOtherFile` — so a trashed take leaves the
    /// metadata log, the player and the compare slot exactly as it always has,
    /// and one that fails to move stays selected for the operator to retry.
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

    /// Items that left the panel leave the selection with them.
    func dropFromSelection(_ gone: Set<URL>) {
        guard !gone.isEmpty else { return }
        selectedItems.subtract(gone)
        if let anchor = selectionAnchor, gone.contains(anchor) {
            selectionAnchor = nil
        }
    }

    /// Anything no longer in the panel is no longer selected — a scan may have
    /// found the day's takes moved off to the archive.
    func pruneSelection() {
        dropFromSelection(selectedItems.subtracting(Set(panelItemOrder)))
    }

    /// Move a take to the Trash and drop it from the session.
    func deleteTake(_ take: Take) {
        do {
            try FileManager.default.trashItem(at: take.url, resultingItemURL: nil)
        } catch {
            lastError = "Delete: \(error.localizedDescription)"
            return
        }
        dropFromSelection([take.url])
        transport.forgetClip(take.url)
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
        dropFromSelection([url])
        transport.forgetClip(url)
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

    /// Rewrite the loop-range sidecar.
    ///
    /// Same discipline as `exportTakeLog`, for the same reason: the whole table,
    /// written atomically, on the one serial queue. Two writers racing could
    /// finish out of order and leave an older snapshot on top of a newer one. The
    /// caller is `TransportModel.onRangesChanged`, which fires only when a range
    /// really moved, so there is nothing here to debounce — scrubbing does not
    /// reach it.
    func exportClipRanges() {
        let ranges = transport.storedRanges
        let root = destinationRoot
        Self.takeLogQueue.async { [weak self] in
            do {
                _ = try TakeLogExporter.writeRanges(ranges, toDirectory: root)
            } catch {
                DispatchQueue.main.async {
                    self?.lastError = "Loop ranges NOT saved: "
                        + error.localizedDescription
                }
            }
        }
    }

    func flashNewItem(_ url: URL) {
        recentlyAddedURL = url
        recentHighlightTask?.cancel()
        recentHighlightTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.recentlyAddedURL = nil
        }
    }
}
