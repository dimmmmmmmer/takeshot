import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// The sync-play offset arithmetic, exact and without media: known start TCs
/// and durations in, expected per-clip seek offsets and window length out.
/// Every synchronized start and every seek is built from these numbers, so a
/// wrong offset here is every tile showing the wrong moment.
struct ModelSyncPlayAlignmentTests {
    private func tc(_ hours: Int, _ minutes: Int, _ seconds: Int,
                    _ frames: Int, fps: Int = 25) -> Timecode {
        Timecode(hours: hours, minutes: minutes, seconds: seconds,
                 frames: frames, fps: fps)
    }

    private func approx(_ value: Double, _ expected: Double,
                        within tolerance: Double = 1e-9) -> Bool {
        abs(value - expected) <= tolerance
    }

    /// Three takes of one scene: the master window is the intersection of the
    /// three TC ranges, and each clip is seeked to where that window starts
    /// inside it.
    @Test func overlappingRangesAlignOnTheirIntersection() {
        // A 10:00:00:00 + 10 s, B 10:00:02:00 + 10 s, C 10:00:01:00 + 5 s
        // ranges: [0,10] [2,12] [1,6] rel. 10:00 → window [2,6], length 4
        let schedule = SyncPlaySchedule.byTimecode(
            startTimecodes: [tc(10, 0, 0, 0), tc(10, 0, 2, 0), tc(10, 0, 1, 0)],
            durations: [10, 10, 5])

        #expect(schedule.usedTimecode)
        #expect(schedule.offsets == [2, 0, 1])
        #expect(schedule.length == 4)
    }

    /// Frame-accurate starts: a take that rolled 12 frames later at 25 fps is
    /// offset by exactly 12/25 s.
    @Test func offsetsResolveToTheFrame() {
        let schedule = SyncPlaySchedule.byTimecode(
            startTimecodes: [tc(10, 0, 0, 0), tc(10, 0, 0, 12)],
            durations: [3, 3])

        #expect(schedule.usedTimecode)
        #expect(approx(schedule.offsets[0], 0.48))
        #expect(approx(schedule.offsets[1], 0))
        // window: [0.48, 3] rel. the first take's start
        #expect(approx(schedule.length, 3 - 0.48))
    }

    /// Mixed rates land in one seconds domain: a 24 fps take against a 25 fps
    /// one aligns on wall-clock TC, not on frame counts.
    @Test func mixedFrameRatesAlignInSeconds() {
        let schedule = SyncPlaySchedule.byTimecode(
            startTimecodes: [tc(10, 0, 0, 0, fps: 25), tc(10, 0, 5, 0, fps: 24)],
            durations: [10, 10])

        #expect(schedule.usedTimecode)
        #expect(schedule.offsets == [5, 0])
        #expect(schedule.length == 5)
    }

    /// Disjoint TC ranges cannot be compared on a shared clock — the schedule
    /// falls back to by-start and says so.
    @Test func disjointRangesFallBackToByStart() {
        let schedule = SyncPlaySchedule.byTimecode(
            startTimecodes: [tc(10, 0, 0, 0), tc(11, 0, 0, 0)],
            durations: [4, 6])

        #expect(!schedule.usedTimecode)
        #expect(schedule.offsets == [0, 0])
        #expect(schedule.length == 6)
    }

    /// Ranges that merely touch (one ends exactly where the other starts)
    /// share no frame — that is a fallback, not a zero-length window.
    @Test func touchingRangesAreNotAnOverlap() {
        let schedule = SyncPlaySchedule.byTimecode(
            startTimecodes: [tc(10, 0, 0, 0), tc(10, 0, 4, 0)],
            durations: [4, 4])

        #expect(!schedule.usedTimecode)
        #expect(schedule.length == 4)
    }

    /// A take without a TC track has no place on the shared clock: the whole
    /// session falls back rather than guessing.
    @Test func aMissingTimecodeFallsBackToByStart() {
        let schedule = SyncPlaySchedule.byTimecode(
            startTimecodes: [tc(10, 0, 0, 0), nil, tc(10, 0, 1, 0)],
            durations: [4, 5, 6])

        #expect(!schedule.usedTimecode)
        #expect(schedule.offsets == [0, 0, 0])
        #expect(schedule.length == 6)
    }

    /// By-start: everything at its own first frame, the transport as long as
    /// the longest take (shorter ones freeze at their end).
    @Test func byStartRunsToTheLongestTake() {
        let schedule = SyncPlaySchedule.byStart(durations: [2.4, 1.2, 3.6, 0.8])

        #expect(!schedule.usedTimecode)
        #expect(schedule.offsets == [0, 0, 0, 0])
        #expect(schedule.length == 3.6)
    }

    /// Identical start TCs: offsets all zero, but the window is clamped to the
    /// SHORTEST take — the honest comparison window, unlike by-start.
    @Test func identicalStartsClampToTheShortestTake() {
        let schedule = SyncPlaySchedule.byTimecode(
            startTimecodes: [tc(10, 0, 0, 0), tc(10, 0, 0, 0)],
            durations: [5, 2])

        #expect(schedule.usedTimecode)
        #expect(schedule.offsets == [0, 0])
        #expect(schedule.length == 2)
    }

    /// The mode switch resolves to the right computation.
    @Test func computeDispatchesOnTheMode() {
        let starts: [Timecode?] = [tc(10, 0, 0, 0), tc(10, 0, 1, 0)]
        let byStart = SyncPlaySchedule.compute(.byStart, startTimecodes: starts,
                                               durations: [4, 4])
        let byTC = SyncPlaySchedule.compute(.byTimecode, startTimecodes: starts,
                                            durations: [4, 4])

        #expect(byStart == SyncPlaySchedule.byStart(durations: [4, 4]))
        #expect(byTC.usedTimecode)
        #expect(byTC.offsets == [1, 0])
        #expect(byTC.length == 3)
    }

    /// Two takes sit side by side; three and four fill a 2×2.
    /// `@MainActor` because the rule lives on the view that lays the grid out.
    @Test @MainActor func gridColumnsMatchTheTileCount() {
        #expect(SyncPlayGrid.columns(for: 2) == 2)
        #expect(SyncPlayGrid.columns(for: 3) == 2)
        #expect(SyncPlayGrid.columns(for: 4) == 2)
    }

    /// **The tiles on screen and the composed picture are laid out by ONE
    /// rule.**
    ///
    /// The same comparison is drawn as SwiftUI tiles for the operator and
    /// composed into one buffer for the hardware output, NDI, SRT and every
    /// browser. Two spellings of "how many across" is how the director's
    /// monitor comes to disagree with the operator's screen about which take is
    /// which — and the labels are only on one of them, so nobody downstream can
    /// tell. Checked across the whole range rather than at the three counts the
    /// mode offers: the agreement is the property, not the three values.
    @Test @MainActor func theTilesAndTheComposedPictureShareOneLayoutRule() {
        for count: Int in 1...6 {
            #expect(SyncPlayGrid.columns(for: count)
                        == MultiviewComposer.columns(cameras: count),
                    "\(count) tiles: the screen and the composed picture disagree")
        }
    }
}
