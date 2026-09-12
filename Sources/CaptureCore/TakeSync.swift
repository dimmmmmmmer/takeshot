import Foundation

/// **Which take a clip off a card IS** (owner: "а можем ли мы рендерить
/// дейлики из сорсов и чтоб пользователь отметил галку допустим «синковать
/// информацию с тейками»").
///
/// A dailies run from a folder of camera originals knows the files and nothing
/// else: the name is the camera's (`C0007.MOV`), and everything the operator
/// marked during the day — the slate, the flags, the in/out — belongs to the
/// app's own recording of the same moment under a different name. So the two
/// have to be matched, and the only thing they share is the CLOCK.
///
/// The arithmetic is `SoundSync`'s and deliberately so: this is the same
/// question about a different pair of files, and the two answers must not
/// drift. Overlap rather than equal starts (a camera rolls before the trigger
/// and stops after it), the same midnight wrap, and the same one-second floor
/// on what counts as sharing a moment.
///
/// # The best match, not every match
///
/// A sound file legitimately belongs to several takes, which is why
/// `SoundSync` answers with a set. This is the other way round: one clip is
/// ONE moment, and a clip that overlaps two takes overlaps one of them by a
/// second and the other by nine minutes. So the answer is the take that shares
/// the most, and ties go to the earlier take — deterministically, because a
/// run that matched differently on a second pass would re-render a day.
public enum TakeSync {
    /// How much a clip and a take have to share before they are the same
    /// moment. `SoundSync`'s floor, for its reason.
    public static let minimumOverlap = SoundSync.minimumOverlap

    /// One take, as this matching needs it: when it started on the day's
    /// clock, how long it ran, and what it knows that a card clip does not.
    ///
    /// A value rather than the `Take` itself because the engine is given
    /// these across an actor boundary and a `Take` carries an image cache's
    /// worth of app state it has no business seeing.
    public struct Candidate: Sendable, Equatable {
        /// Seconds since midnight at the take's first frame.
        public var start: Double
        public var duration: Double
        /// What the operator called it — the burn-in's clip name.
        public var name: String
        public var slate: SlateMetadata
        public var markers: [TakeMarker]
        /// The in/out marked during review, which is what the whole feature
        /// is for.
        public var range: ClipRange?
        public var rating: TakeRating

        public init(start: Double, duration: Double, name: String,
                    slate: SlateMetadata = .empty,
                    markers: [TakeMarker] = [], range: ClipRange? = nil,
                    rating: TakeRating = .none) {
            self.start = start
            self.duration = duration
            self.name = name
            self.slate = slate
            self.markers = markers
            self.range = range
            self.rating = rating
        }
    }

    /// **The day's takes as candidates**, with the in/out the operator
    /// marked against each of them.
    ///
    /// A take with no start timecode is left out entirely rather than placed
    /// at midnight: it has no position on the day's clock, so nothing can be
    /// matched to it and a zero would match whatever was shot at 00:00.
    ///
    /// `ranges` is keyed the way the transport keys it — by file name — and a
    /// take with no mark is still a candidate: the name, the slate and the
    /// flags are worth carrying across on their own.
    public static func candidates(from takes: [Take],
                                  ranges: [String: ClipRange] = [:])
        -> [Candidate] {
        takes.compactMap { take in
            guard let start = take.startTimecode else { return nil }
            let rate = TakeLogExporter.realRate(for: take)
            return Candidate(
                start: Double(start.frameNumber) / max(1, rate),
                duration: take.durationSeconds.isFinite
                    ? max(0, take.durationSeconds) : 0,
                name: take.displayName, slate: take.slate,
                markers: take.markers,
                range: ranges[TakeRuntime.key(take)], rating: take.rating)
        }
    }

    /// The take a clip belongs to, or nil.
    ///
    /// `clipStart` is seconds since midnight at the clip's first frame — its
    /// own timecode — and a clip with none matches nothing rather than
    /// matching whatever happened at midnight.
    public static func match(clipStart: Double?, clipDuration: Double,
                             in takes: [Candidate],
                             minimumOverlap: Double = minimumOverlap)
        -> Candidate? {
        guard let clipStart, clipDuration > 0 else { return nil }
        let clipEnd = clipStart + clipDuration
        var best: Candidate?
        var bestShared = 0.0
        for take in takes {
            let start = SoundSync.wrapped(take.start, near: clipStart)
            let shared = min(clipEnd, start + take.duration)
                - max(clipStart, start)
            guard shared >= minimumOverlap, shared > bestShared else { continue }
            best = take
            bestShared = shared
        }
        return best
    }

    /// **What a match does to the item**: the take's own name and slate on the
    /// burn-ins, its flags as the proxy's chapters, and its in/out as the
    /// trim.
    ///
    /// What it deliberately does NOT touch is the output NAME. The file on
    /// disk is the camera's and the journal's whole relationship with it is by
    /// that name — renaming the output because a take was matched would make
    /// every previously rendered daily unrecognisable to the next run.
    public static func applied(_ take: Candidate,
                               to item: DailiesItem) -> DailiesItem {
        var synced = item
        synced.clipName = take.name.isEmpty ? item.clipName : take.name
        synced.markers = take.markers
        synced.range = take.range
        return synced
    }
}
