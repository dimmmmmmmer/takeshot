import Foundation
import Testing

@testable import CaptureCore

/// **The part of a source a daily is made from** (owner: "чтоб у нас ин/аут
/// сработал таким образом").
///
/// A trimmed read keeps the clip's own timeline — which is what a proxy wants
/// and is also the trap, because two of the three tracks written beside the
/// picture are positioned from ZERO and land a whole in-point out if they are
/// not re-based.
@Suite struct DailiesTrimTests {
    private let rate = 25.0

    private func anchor(_ seconds: Double, _ tc: String) -> DailiesTimeline.Anchor {
        DailiesTimeline.Anchor(
            seconds: seconds,
            timecode: Timecode(text: tc, fps: 25) ?? Timecode(frameNumber: 0,
                                                              fps: 25))
    }

    // MARK: - the window

    @Test func aMarkNarrowsTheClip() {
        let window = DailiesTrim.window(ClipRange(inPoint: 4, outPoint: 20),
                                        duration: 60)
        #expect(window?.start == 4)
        #expect(window?.end == 20)
    }

    /// The four ways a mark says nothing, which are `TakeRuntime.window`'s and
    /// for the same reasons.
    @Test func aMarkThatSelectsNothingIsNotATrim() {
        #expect(DailiesTrim.window(nil, duration: 60) == nil)
        #expect(DailiesTrim.window(ClipRange(inPoint: 20, outPoint: 4),
                                   duration: 60) == nil)
        #expect(DailiesTrim.window(ClipRange(inPoint: 0, outPoint: 60),
                                   duration: 60) == nil)
        #expect(DailiesTrim.window(ClipRange(inPoint: 4), duration: 0) == nil)
        #expect(DailiesTrim.window(ClipRange(inPoint: 4), duration: .nan) == nil)
    }

    /// Half a mark is still a mark, and it is clamped into the clip.
    @Test func aHalfSetMarkRunsToTheClipsOwnEdge() {
        #expect(DailiesTrim.window(ClipRange(inPoint: 4),
                                   duration: 60)?.end == 60)
        #expect(DailiesTrim.window(ClipRange(outPoint: 20),
                                   duration: 60)?.start == 0)
        #expect(DailiesTrim.window(ClipRange(inPoint: 4, outPoint: 900),
                                   duration: 60)?.end == 60)
    }

    // MARK: - the clock

    /// **The first span has to carry the timecode AT the in point.** A proxy
    /// whose timecode is forty seconds out is worse than one with none,
    /// because it looks right.
    @Test func theAnchorsAreRebasedOntoTheInPoint() {
        let rebased = DailiesTrim.anchors([anchor(0, "10:00:00:00")],
                                          from: 4, frameRate: rate)
        #expect(rebased.count == 1)
        #expect(rebased[0].seconds == 4)
        #expect(rebased[0].timecode.description == "10:00:04:00")
    }

    /// A camera that re-anchored mid-shot keeps both readings — the ones
    /// inside the window, after the one at its start.
    @Test func anAnchorInsideTheWindowSurvivesWithIt() {
        let rebased = DailiesTrim.anchors(
            [anchor(0, "10:00:00:00"), anchor(10, "11:00:00:00")],
            from: 4, frameRate: rate)
        #expect(rebased.map(\.seconds) == [4, 10])
        #expect(rebased.map(\.timecode.description)
            == ["10:00:04:00", "11:00:00:00"])
    }

    /// …and one before it does not: it describes frames this daily has none of.
    @Test func anAnchorBeforeTheWindowIsDropped() {
        let rebased = DailiesTrim.anchors(
            [anchor(0, "10:00:00:00"), anchor(2, "11:00:00:00")],
            from: 4, frameRate: rate)
        #expect(rebased.count == 1)
        // the clock at the in point: two seconds past the later anchor
        #expect(rebased[0].timecode.description == "11:00:02:00")
    }

    /// A source with no timecode gets no timecode track, trimmed or not.
    @Test func noAnchorsInIsNoAnchorsOut() {
        #expect(DailiesTrim.anchors([], from: 4, frameRate: rate).isEmpty)
    }

    // MARK: - the chapters

    /// A chapter is placed against the media from frame zero, so a marker five
    /// seconds into the SOURCE is five seconds into the source — not five
    /// seconds after the in point.
    @Test func markersAreRebasedOntoTheInPoint() {
        let moved = DailiesTrim.markers(
            [TakeMarker(seconds: 6, note: "focus")], from: 4, until: 20)
        #expect(moved.map(\.seconds) == [2])
        #expect(moved.map(\.note) == ["focus"])
    }

    /// Outside is DROPPED and not clamped: a chapter at the first frame for a
    /// moment that is not in the file is worse than no chapter, and an
    /// operator who trimmed a take meant to leave that part out.
    @Test func markersOutsideTheWindowAreDropped() {
        let moved = DailiesTrim.markers(
            [TakeMarker(seconds: 1), TakeMarker(seconds: 6),
             TakeMarker(seconds: 25)], from: 4, until: 20)
        #expect(moved.map(\.seconds) == [2])
    }

    // MARK: - the recipe

    /// A folder rendered whole is not "already rendered" for a run that trims,
    /// and the other way round.
    @Test func theMarksAreInTheItemsRecipe() {
        #expect(DailiesTrim.recipePart(nil).isEmpty)
        #expect(DailiesTrim.recipePart(ClipRange()).isEmpty)
        #expect(DailiesTrim.recipePart(ClipRange(inPoint: 4, outPoint: 20))
            == "|trim:4.000-20.000")
        #expect(DailiesTrim.recipePart(ClipRange(inPoint: 4))
            == "|trim:4.000-")
        #expect(DailiesTrim.recipePart(ClipRange(inPoint: 4, outPoint: 20))
            != DailiesTrim.recipePart(ClipRange(inPoint: 5, outPoint: 20)))
    }
}
