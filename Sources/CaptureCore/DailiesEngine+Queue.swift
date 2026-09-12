import Foundation

/// **The two outcomes a queued item can have before anything is opened**: the
/// run has nowhere to write, or the item was never meant to be rendered.
///
/// Split out of the engine when that type reached its length ceiling, and a
/// coherent cut: both are answers the loop gives WITHOUT touching the item's
/// media, and both exist to keep one rule — a report's length always matches
/// the queue's, so nothing goes missing between what was asked for and what
/// came back.
extension DailiesEngine {
    /// The destination folder, made — or the report a run that has nowhere to
    /// write comes back as, with every item saying why.
    static func openDestination(_ folder: URL,
                                for items: [DailiesItem])
        -> DailiesReport? {
        do {
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true)
            return nil
        } catch {
            return DailiesReport(items: items.map {
                DailiesItemResult(source: $0.source,
                                  failure: error.localizedDescription)
            }, wasCancelled: false)
        }
    }

    /// **Left out because the run was asked for the circled takes only.**
    ///
    /// A clip that matched NOTHING is left out too, and that is the literal
    /// reading rather than a harsh one: the switch says only the circled
    /// takes, and a clip no take covers is not a circled take. It is REPORTED
    /// rather than dropped, so the panel says how many were left instead of
    /// leaving an unexplained gap between what was queued and what was made —
    /// and it ticks the bar, for the reason a skip does.
    static func filtered(
        _ item: DailiesItem, at place: (index: Int, count: Int),
        progress: @Sendable (DailiesProgress) -> Void) -> DailiesItemResult {
        progress(DailiesProgress(
            itemIndex: place.index, itemCount: place.count,
            currentFile: item.source.lastPathComponent,
            framesDone: 1, framesTotal: 1, isPaused: false,
            isCancelling: false))
        return DailiesItemResult(source: item.source, wasFiltered: true)
    }
}
