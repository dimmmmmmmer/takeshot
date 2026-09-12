import Foundation

/// **The part of a source a daily is made from** (owner: "а можем ли мы
/// рендерить дейлики из сорсов и чтоб пользователь отметил галку допустим
/// «синковать информацию с тейками», чтоб у нас ин/аут сработал таким
/// образом?").
///
/// An in/out is marked during review. It reaches the shift report, and — since
/// the timelines learned to place a clip by it — the EDL and both XML exports
/// as well, where the media stays whole and only the CLIP is cut.
///
/// Applied to a daily it is the difference between sending the unit a
/// nine-minute roll and sending them the forty seconds somebody circled.
///
/// # Everything here is about one thing: the clip's own timeline is kept
///
/// `AVAssetReader.timeRange` does not re-stamp what it hands back — a trimmed
/// read produces the samples that were always there, with the presentation
/// times they always had. That is exactly what a proxy wants (its timecode
/// still describes the camera original) and it is also the trap: two of the
/// three tracks written beside the picture are positioned from ZERO, and both
/// of them land a whole in-point out if they are not re-based.
///
/// - the timecode track states an absolute timecode per span, so the first
///   span has to carry the timecode AT the in point rather than the clip's
///   start — a proxy whose timecode is forty seconds out is worse than one
///   with no timecode at all, because it looks right;
/// - a chapter is placed against the MEDIA from frame zero, so a marker five
///   seconds into the source is five seconds into the source and not five
///   seconds after the in point.
public enum DailiesTrim {
    /// The window a range selects inside a clip of `duration`, clamped — or
    /// nil when nothing narrows it.
    ///
    /// The same four refusals `TakeRuntime.window` makes about a take, for the
    /// same reasons: no mark, an unreadable length, an out at or before the
    /// in, and a window that spans the whole clip. A trim that selects
    /// everything is not a trim, and the run is the run it always was.
    public static func window(_ range: ClipRange?,
                              duration: Double) -> (start: Double, end: Double)? {
        guard let range, duration.isFinite, duration > 0 else { return nil }
        let start = min(max(0, range.inPoint ?? 0), duration)
        let end = min(max(0, range.outPoint ?? duration), duration)
        guard end > start, end - start < duration else { return nil }
        return (start, end)
    }

    /// The timecode anchors of a trimmed clip.
    ///
    /// One anchor AT the in point carrying the timecode there, then whatever
    /// anchors fall inside the window. The first is the whole point: a clip
    /// whose camera re-anchored mid-shot keeps both readings, and one that
    /// never did still starts at the right number.
    ///
    /// An empty list in is an empty list out — a source with no timecode gets
    /// no timecode track, trimmed or not.
    public static func anchors(_ anchors: [DailiesTimeline.Anchor],
                               from start: Double,
                               frameRate: Double) -> [DailiesTimeline.Anchor] {
        guard !anchors.isEmpty else { return [] }
        let timeline = DailiesTimeline(anchors: anchors, frameRate: frameRate)
        let head = DailiesTimeline.Anchor(
            seconds: start, timecode: timeline.timecode(atSeconds: start))
        return [head] + anchors.filter { $0.seconds > start }
    }

    /// The markers inside a window, as offsets from its start.
    ///
    /// Outside is DROPPED rather than clamped to the edge: a chapter at the
    /// first frame for a moment that is not in the file is a worse answer than
    /// no chapter, and an operator who trimmed a take meant to leave that part
    /// out.
    public static func markers(_ markers: [TakeMarker], from start: Double,
                               until end: Double) -> [TakeMarker] {
        markers.compactMap { marker in
            guard marker.seconds >= start, marker.seconds < end else {
                return nil
            }
            var moved = marker
            moved.seconds = marker.seconds - start
            return moved
        }
    }

    /// What a trimmed item adds to a recipe, so a folder rendered whole is not
    /// "already rendered" for a run that trims — and the other way round.
    ///
    /// Per ITEM and not per run, which is why it is not inside
    /// `DailiesRecipe.fingerprint`: every take has its own marks, and a run
    /// whose recipe could not say so would skip a take whose in point moved.
    /// Empty for an unmarked item, so every fingerprint ever written is
    /// unchanged.
    ///
    /// **The MARKS and not the window**, which is the one place those two
    /// differ on purpose: a window needs the clip's own duration and the
    /// recipe is decided before anything is opened. The cost is a mark that
    /// happens to select the whole clip — it re-renders a file it would have
    /// produced identically, which is the safe direction to be wrong in.
    public static func recipePart(_ range: ClipRange?) -> String {
        guard let range, !range.isEmpty else { return "" }
        let inPoint = range.inPoint.map { String(format: "%.3f", $0) } ?? ""
        let outPoint = range.outPoint.map { String(format: "%.3f", $0) } ?? ""
        return "|trim:\(inPoint)-\(outPoint)"
    }
}
