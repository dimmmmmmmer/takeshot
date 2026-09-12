@preconcurrency import AVFoundation
import Foundation

/// **Which take each clip off a card IS**, resolved before a run starts.
///
/// Split out of the engine when that type reached its length ceiling, and a
/// coherent piece rather than an arbitrary cut: this is one pass over the
/// queue asking one question of each file, and the answer changes what the
/// item IS — its burn-in name, its chapters and the part of it that gets
/// rendered at all.
///
/// Why it happens HERE and not inside the transcode is the interesting half,
/// and it is written at the call site: the trim is part of an item's recipe,
/// so the skip decision and the note written after it both have to be about
/// the item as it will actually be rendered.
extension DailiesEngine {
    /// **Every item with its matched take applied**, or the items untouched
    /// when there is nothing to match against.
    ///
    /// One timecode read per source, which is a fraction of a second against
    /// the decode each of them is about to get — and the read the transcode
    /// makes later is a different question of the same file rather than a
    /// duplicated cost worth avoiding by threading the answer through.
    ///
    /// A clip that matches nothing is left exactly as it was: a card holds
    /// footage from before the app was running, and a run must not refuse it.
    static func resolve(_ items: [DailiesItem],
                        syncWith takes: [TakeSync.Candidate])
        async -> [DailiesItem] {
        guard !takes.isEmpty else { return items }
        var resolved: [DailiesItem] = []
        for item in items {
            let asset = AVURLAsset(url: item.source)
            let anchors = await TimecodeReader.timelineAnchors(of: asset)
            let rate = (try? await asset.tracks(ofType: .video).first?
                .load(.nominalFrameRate)).flatMap { $0.map(Double.init) } ?? 25
            let duration = (try? await asset.load(.duration).seconds) ?? 0
            let start = timecodeTrack(anchors: anchors, item: item).first.map {
                Double($0.timecode.frameNumber) / max(1, rate)
            }
            guard let take = TakeSync.match(clipStart: start,
                                            clipDuration: duration,
                                            in: takes) else {
                resolved.append(item)
                continue
            }
            resolved.append(TakeSync.applied(take, to: item))
        }
        return resolved
    }
}
