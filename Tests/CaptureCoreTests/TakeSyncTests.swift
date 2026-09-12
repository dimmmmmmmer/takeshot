import Foundation
import Testing

@testable import CaptureCore

/// **Which take a clip off a card IS** (owner: "чтоб пользователь отметил
/// галку допустим «синковать информацию с тейками»").
///
/// The names never match — the camera's clip is `C0007` and the app's
/// recording of the same moment is `A001C001` — so the clock is the only thing
/// the two share, and everything here is about that arithmetic.
@Suite struct TakeSyncTests {
    private func candidate(_ name: String, start: Double, duration: Double,
                           rating: TakeRating = .none,
                           range: ClipRange? = nil) -> TakeSync.Candidate {
        TakeSync.Candidate(start: start, duration: duration, name: name,
                           slate: SlateMetadata(scene: "12", shot: 1, take: 3),
                           markers: [TakeMarker(seconds: 2, note: "focus")],
                           range: range, rating: rating)
    }

    /// 10:00:00 on the day's clock, in seconds since midnight.
    private let ten = 10.0 * 3600

    @Test func aClipThatOverlapsATakeIsThatTake() {
        let takes = [candidate("A001C001", start: ten, duration: 60)]
        let match = TakeSync.match(clipStart: ten - 2, clipDuration: 70,
                                   in: takes)
        #expect(match?.name == "A001C001")
    }

    /// A camera rolls before the trigger and stops after it, so equal starts
    /// would match almost nothing on a real day — the rule is overlap, exactly
    /// as it is for sound.
    @Test func theRuleIsOverlapAndNotEqualStarts() {
        let takes = [candidate("A001C001", start: ten + 3, duration: 40)]
        #expect(TakeSync.match(clipStart: ten, clipDuration: 50,
                               in: takes)?.name == "A001C001")
    }

    /// A clip that merely TOUCHES a take is not that take: the tail of one
    /// slate and the head of the next overlap by a moment, and a second of
    /// shared picture is the floor `SoundSync` already uses.
    @Test func aClipThatOnlyTouchesATakeDoesNotMatchIt() {
        let takes = [candidate("A001C001", start: ten, duration: 60)]
        // ends half a second after the take starts
        #expect(TakeSync.match(clipStart: ten - 30, clipDuration: 30.5,
                               in: takes) == nil)
        // …and a second of it does match
        #expect(TakeSync.match(clipStart: ten - 30, clipDuration: 31,
                               in: takes) != nil)
    }

    /// **One clip is ONE moment.** A clip that laps into the next take shares
    /// a second with it and nine minutes with its own, so the answer is the
    /// take it shares the most with.
    @Test func theBestMatchWinsAndNotTheFirst() {
        let takes = [candidate("A001C001", start: ten - 120, duration: 121),
                     candidate("A001C002", start: ten, duration: 300)]
        #expect(TakeSync.match(clipStart: ten, clipDuration: 300,
                               in: takes)?.name == "A001C002")
    }

    /// A clip with no timecode matches nothing rather than matching whatever
    /// happened at midnight.
    @Test func aClipWithNoTimecodeMatchesNothing() {
        let takes = [candidate("A001C001", start: 0, duration: 60)]
        #expect(TakeSync.match(clipStart: nil, clipDuration: 60,
                               in: takes) == nil)
        #expect(TakeSync.match(clipStart: 10, clipDuration: 0,
                               in: takes) == nil)
        #expect(TakeSync.match(clipStart: ten, clipDuration: 60,
                               in: []) == nil)
    }

    /// A take that rolled through midnight ends on a SMALLER timecode than it
    /// started on — the same fold the markers and the sound already make.
    @Test func aTakeThroughMidnightStillMatches() {
        // the take starts at 23:59:30 and the clip at 23:59:29
        let takes = [candidate("A001C001", start: 86_370, duration: 60)]
        #expect(TakeSync.match(clipStart: 86_369, clipDuration: 70,
                               in: takes) != nil)
        // …and a clip just after midnight is a second into it, not a day out
        #expect(TakeSync.match(clipStart: 5, clipDuration: 30,
                               in: takes) != nil)
    }

    // MARK: - what a match does

    /// The take's name, flags and in/out — and NOT the output name: the file
    /// on disk is the camera's and the journal's whole relationship with it is
    /// by that name.
    @Test func aMatchBringsTheNameTheFlagsAndTheInOut() {
        let item = DailiesItem(source: URL(fileURLWithPath: "/tmp/C0007.MOV"),
                               outputName: "C0007_DAILY", clipName: "C0007")
        let take = candidate("A001C001", start: ten, duration: 60,
                             range: ClipRange(inPoint: 4, outPoint: 20))
        let synced = TakeSync.applied(take, to: item)
        #expect(synced.clipName == "A001C001")
        #expect(synced.markers.map(\.note) == ["focus"])
        #expect(synced.range == ClipRange(inPoint: 4, outPoint: 20))
        #expect(synced.outputName == "C0007_DAILY",
                "the output was renamed out from under the journal")
        #expect(synced.source == item.source)
    }

    /// A take with no name of its own leaves the clip's alone rather than
    /// burning an empty strip.
    @Test func aNamelessTakeLeavesTheClipsNameAlone() {
        let item = DailiesItem(source: URL(fileURLWithPath: "/tmp/C0007.MOV"),
                               outputName: "C0007_DAILY", clipName: "C0007")
        let synced = TakeSync.applied(candidate("", start: ten, duration: 60),
                                      to: item)
        #expect(synced.clipName == "C0007")
    }
    // MARK: - the day's takes as candidates

    /// A take with no start timecode is left out entirely rather than placed
    /// at midnight: it has no position on the day's clock, and a zero would
    /// match whatever was shot at 00:00.
    @Test func aTakeWithNoTimecodeIsNotACandidate() {
        let timed = Take(url: URL(fileURLWithPath: "/tmp/A001C001.mov"),
                         scene: "12", roll: "A001", takeNumber: 1,
                         startTimecode: Timecode(hours: 10, minutes: 0,
                                                 seconds: 0, frames: 0,
                                                 fps: 25),
                         durationSeconds: 12,
                         recordedAt: Date(timeIntervalSince1970: 0))
        var untimed = timed
        untimed.startTimecode = nil
        let candidates = TakeSync.candidates(from: [timed, untimed])
        #expect(candidates.count == 1)
        #expect(candidates[0].start == 10 * 3600)
        #expect(candidates[0].duration == 12)
        #expect(candidates[0].name == "A001C001")
    }

    /// The marks come in keyed the way the transport keys them, by file name.
    @Test func theMarksAreLookedUpByFileName() {
        var take = Take(url: URL(fileURLWithPath: "/tmp/A001C001.mov"),
                        scene: "12", roll: "A001", takeNumber: 1,
                        startTimecode: Timecode(hours: 10, minutes: 0,
                                                seconds: 0, frames: 0, fps: 25),
                        durationSeconds: 12,
                        recordedAt: Date(timeIntervalSince1970: 0))
        take.rating = .good
        let candidates = TakeSync.candidates(
            from: [take],
            ranges: ["A001C001.mov": ClipRange(inPoint: 2, outPoint: 8)])
        #expect(candidates[0].range == ClipRange(inPoint: 2, outPoint: 8))
        #expect(candidates[0].rating == .good)
        // …and a take nobody marked is still a candidate: the name, the slate
        // and the flags are worth carrying on their own
        #expect(TakeSync.candidates(from: [take])[0].range == nil)
    }

    /// A length that came back non-finite is not a duration to overlap
    /// against, and a NaN would make every comparison false anyway.
    @Test func anUnreadableLengthBecomesZero() {
        var take = Take(url: URL(fileURLWithPath: "/tmp/A.mov"),
                        scene: "", roll: "", takeNumber: 1,
                        startTimecode: Timecode(hours: 10, minutes: 0,
                                                seconds: 0, frames: 0, fps: 25),
                        durationSeconds: .nan,
                        recordedAt: Date(timeIntervalSince1970: 0))
        take.durationSeconds = .nan
        #expect(TakeSync.candidates(from: [take])[0].duration == 0)
    }

}
