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
