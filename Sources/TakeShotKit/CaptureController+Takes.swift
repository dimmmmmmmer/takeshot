import CaptureCore
import Foundation

/// What the operator marks on a take — the rating and the comment — and the
/// sidecars those are written to.
///
/// Split out of CaptureController+Library: scanning the folder and editing what
/// was found are separate jobs. Clicking around the panel is `+Selection`,
/// removing an item is `+Trash`.
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

    /// Set a take's rating. A rating it already has is nothing at all — the
    /// same guard `setComment` and `setSlate` carry, and it was the one of the
    /// three without it.
    ///
    /// That is not tidiness. `exportTakeLog` rewrites four sidecar files on the
    /// record volume, and the web remote's `rate` command lands here: without
    /// the guard, a page repeating the rating a take already has is one full
    /// rewrite per message, on the disk a take is being written to.
    func setRating(_ rating: TakeRating, for take: Take) {
        guard let idx = takes.firstIndex(where: { $0.id == take.id }) else { return }
        guard takes[idx].rating != rating else { return }
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

    // MARK: - the sidecars beside the footage

    /// Resolve-compatible CSV: rewritten on every take and every circle-take mark
    /// — in Resolve it's imported via Media Pool → Import Metadata.
    func exportTakeLog() {
        let takes = (takes + retiredTakes).sorted { $0.recordedAt < $1.recordedAt }
        let root = destinationRoot
        // Markers on clips that are not ours go into the same sidecar under
        // their file names. Snapshotted here with the takes, on the actor, so
        // the queue below writes one consistent picture of the folder.
        //
        // A name that is now a take's is dropped rather than written twice: the
        // sidecar is keyed by name and the reader merges every row under one, so
        // a file that arrived as foreign and was later adopted (a TakeShot
        // recording copied in from another folder carries our tag) would
        // otherwise put its old rows onto the take as well.
        let takeNames = Set(takes.map { $0.url.lastPathComponent })
        let other = otherMarkers.filter {
            !$0.value.isEmpty && !takeNames.contains($0.key)
        }
        Self.takeLogQueue.async { [weak self] in
            do {
                _ = try TakeLogExporter.write(takes: takes, toDirectory: root)
                _ = try TakeLogExporter.writeMarkers(takes: takes, other: other,
                                                     toDirectory: root)
                // The creative fields do not fit the frozen Resolve schema, so
                // they get their own sidecar — written here, with the log, so
                // one edit produces one consistent picture of the folder.
                _ = try TakeLogExporter.writeSlates(takes: takes,
                                                    toDirectory: root)
            } catch {
                // ratings/comments silently not persisting is a day-loss bug
                DispatchQueue.main.async {
                    self?.lastError = L("toast_metadata_log_not_saved",
                                        error.localizedDescription)
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
                    self?.lastError = L("toast_ranges_not_saved",
                                        error.localizedDescription)
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
