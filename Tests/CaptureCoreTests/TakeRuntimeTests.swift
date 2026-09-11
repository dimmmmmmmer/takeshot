import Foundation
import Testing

@testable import CaptureCore

/// **What the circled takes came to**, which is the number the production
/// office asks for at wrap and is not the day's footage with the rejects
/// dropped: a circled take carries the in/out the operator marked during
/// review, and the part between those two marks is what goes forward.
///
/// Everything here is arithmetic on a mark, and the four ways a mark can say
/// nothing are what most of it is about — each of them is a way a runtime
/// silently comes out wrong on a piece of paper that leaves set.
@Suite struct TakeRuntimeTests {
    private func take(_ index: Int, rating: TakeRating = .good,
                      duration: Double = 12,
                      fps: Int = 25, drop: Bool = false,
                      frameRate: Double? = nil) -> Take {
        var take = Take(
            url: URL(fileURLWithPath: "/tmp/CLIP\(index).mov"),
            scene: "", roll: "001", takeNumber: index,
            startTimecode: Timecode(hours: 10, minutes: 0, seconds: 0,
                                    frames: 0, fps: fps, isDropFrame: drop),
            durationSeconds: duration,
            recordedAt: Date(timeIntervalSince1970: 0),
            frameRate: frameRate)
        take.rating = rating
        return take
    }

    /// One clip's mark, filed the way the transport files it — by file name.
    private func ranges(_ index: Int, _ range: ClipRange) -> [String: ClipRange] {
        ["CLIP\(index).mov": range]
    }

    // MARK: - one take's window

    @Test func anUnmarkedTakeCountsWhole() {
        let subject: Take = take(1)
        #expect(TakeRuntime.window(of: subject, range: nil) == nil)
        #expect(TakeRuntime.seconds(of: subject, range: nil) == 12)
        #expect(TakeRuntime.seconds(of: subject, range: .unset) == 12)
    }

    @Test func aMarkedTakeCountsOnlyTheMarkedPart() {
        let subject: Take = take(1)
        let range = ClipRange(inPoint: 2, outPoint: 10)
        #expect(TakeRuntime.seconds(of: subject, range: range) == 8)
        let window = TakeRuntime.window(of: subject, range: range)
        #expect(window?.start == 2)
        #expect(window?.end == 10)
    }

    /// Half a range is still a mark the operator made — the sidecar keeps one
    /// (`TakeLogExporter.parseRanges`), so the runtime has to read one.
    @Test func anOpenEndedMarkRunsToTheTakesOwnEdge() {
        let subject: Take = take(1)
        #expect(TakeRuntime.seconds(of: subject,
                                    range: ClipRange(inPoint: 2)) == 10)
        #expect(TakeRuntime.seconds(of: subject,
                                    range: ClipRange(outPoint: 5)) == 5)
    }

    /// An out point at or before the in point selects nothing, and "nothing"
    /// is the one answer that must not reach the total: subtracting the whole
    /// take from the day's runtime on the strength of a broken mark is a
    /// worse answer than ignoring the mark.
    @Test func anOutBeforeTheInIsNotASelection() {
        let subject: Take = take(1)
        for range in [ClipRange(inPoint: 10, outPoint: 2),
                      ClipRange(inPoint: 6, outPoint: 6)] {
            #expect(TakeRuntime.window(of: subject, range: range) == nil)
            #expect(TakeRuntime.seconds(of: subject, range: range) == 12)
        }
    }

    /// A mark left over from a clip re-recorded under the same name, or a
    /// sidecar edited by hand. Clamped into the take rather than trusted: an
    /// out point past the end would otherwise print beyond the take's own End
    /// TC in the row above it, and add footage that was never shot.
    @Test func aMarkPastTheEndIsClampedIntoTheTake() {
        let subject: Take = take(1)
        let window = TakeRuntime.window(of: subject,
                                        range: ClipRange(inPoint: 5, outPoint: 999))
        #expect(window?.end == 12)
        #expect(TakeRuntime.seconds(of: subject,
                                    range: ClipRange(inPoint: 5, outPoint: 999)) == 7)
    }

    /// A window spanning the whole take is a mark that changes no number, and
    /// counting it as a trim would make the sheet claim an in/out that took
    /// nothing off.
    @Test func aWindowOverTheWholeTakeIsNotATrim() {
        let subject: Take = take(1)
        #expect(TakeRuntime.window(of: subject,
                                   range: ClipRange(inPoint: 0, outPoint: 12)) == nil)
        #expect(TakeRuntime.window(of: subject,
                                   range: ClipRange(inPoint: 0, outPoint: 99)) == nil)
    }

    /// `CMTime.seconds` of an indefinite time is NaN, and a NaN duration has
    /// no window to mark inside it.
    @Test func anUnreadableLengthHasNoWindow() {
        var subject: Take = take(1)
        subject.durationSeconds = .nan
        let range = ClipRange(inPoint: 2, outPoint: 10)
        #expect(TakeRuntime.window(of: subject, range: range) == nil)
        #expect(TakeRuntime.seconds(of: subject, range: range) == 0)
    }

    // MARK: - the day's total

    @Test func theTotalCountsOnlyTheCircledTakes() {
        let material = TakeRuntime.ReportMaterial(
            [take(1, duration: 900), take(2, duration: 900),
             take(3, rating: .bad, duration: 900),
             take(4, rating: .none, duration: 900)])
        let selects: TakeRuntime.Selects = TakeRuntime.selects(of: material)
        #expect(selects.count == 2)
        #expect(selects.whole == 1800)
        #expect(selects.marked == 1800)
        #expect(!selects.isTrimmed)
    }

    @Test func theTotalHonoursTheMarksOnTheCircledTakes() {
        let material = TakeRuntime.ReportMaterial(
            [take(1, duration: 900), take(2, duration: 900)],
            ranges: ranges(1, ClipRange(inPoint: 100, outPoint: 400)))
        let selects: TakeRuntime.Selects = TakeRuntime.selects(of: material)
        #expect(selects.whole == 1800)
        #expect(selects.marked == 1200, "900 − 600 taken off take 1")
        #expect(selects.markedCount == 1)
        #expect(selects.isTrimmed)
    }

    /// A mark on a take nobody circled is review state about a take that is
    /// not going forward; it must not move the selects runtime.
    @Test func aMarkOnATakeThatIsNotCircledChangesNothing() {
        let takes = [take(1, duration: 900), take(2, rating: .bad, duration: 900)]
        let plain = TakeRuntime.selects(of: TakeRuntime.ReportMaterial(takes))
        let marked = TakeRuntime.selects(of: TakeRuntime.ReportMaterial(
            takes, ranges: ranges(2, ClipRange(inPoint: 10, outPoint: 20))))
        #expect(plain == marked)
        #expect(!marked.isTrimmed)
    }

    /// One NaN and the whole total is NaN, which is the trap `ClipTimeText`
    /// documents one level up — the clock that survives it is only asked
    /// afterwards, so the sum has to be the thing that guards.
    @Test func oneUnreadableLengthDoesNotPoisonTheTotal() {
        // BOTH shapes, because they fail differently: `max(0, .nan)` answers
        // 0 in Swift all by itself, so NaN alone cannot tell whether the guard
        // is there — an infinite length is what proves it.
        for unreadable in [Double.nan, .infinity] {
            var takes = [take(1, duration: 900), take(2, duration: 900)]
            takes[0].durationSeconds = unreadable
            let material = TakeRuntime.ReportMaterial(takes)
            let selects = TakeRuntime.selects(of: material)
            #expect(selects.count == 2, "it was still shot and still circled")
            #expect(selects.whole == 900, "\(unreadable)")
            #expect(selects.marked == 900, "\(unreadable)")
            // and the day's footage costs that take's own length, not the day
            #expect(TakeRuntime.footage(of: takes) == 900, "\(unreadable)")
        }
    }

    // MARK: - what the marks print as

    /// A mark and a marker in the same row have to land on the same clock —
    /// both go through the marker's own converter, so an absolute take gets
    /// absolute positions.
    @Test func aMarkPrintsOnTheTakesOwnClock() {
        let subject: Take = take(1, duration: 900)
        #expect(TakeRuntime.markTimecode(of: subject, atSecond: 0)
            == "10:00:00:00")
        #expect(TakeRuntime.markTimecode(of: subject, atSecond: 2)
            == "10:00:02:00")
    }

    /// …and a take the camera gave no timecode for counts from zero on both
    /// sides of the row, exactly as its markers do.
    @Test func aMarkOnATakeWithNoTimecodeCountsFromZero() {
        var subject: Take = take(1, duration: 900)
        subject.startTimecode = nil
        #expect(TakeRuntime.markTimecode(of: subject, atSecond: 2)
            == "00:00:02:00")
    }

    /// The marked LENGTH is counted on the take's REAL rate — a 23.976 take
    /// numbered at 24 came out a frame long every 41 s, which is the drift
    /// `TakeSpan` was built to end.
    @Test func aMarkedLengthIsCountedOnTheTakesRealRate() {
        let subject: Take = take(1, duration: 900, fps: 24,
                                 frameRate: 24 * 1000 / 1001)
        // 900 s at 23.976 is 21 578 frames, which the 24 fps numbering above
        // reads as 14:59:02 — against a round 15:00:00 for 21 600 frames, the
        // count of a take that really ran at 24
        #expect(TakeRuntime.lengthTimecode(900, of: subject) == "00:14:59:02")
        #expect(TakeRuntime.lengthTimecode(900, of: take(2, duration: 900, fps: 24))
            == "00:15:00:00")
    }

    /// The whole take's length is the same arithmetic asked about the whole
    /// take, so the two lengths in one row cannot be counted two ways.
    @Test func theRecordedLengthIsTheSameArithmetic() {
        for subject in [take(1, duration: 12.4),
                        take(2, duration: 900, fps: 30, drop: true)] {
            #expect(TakeLogExporter.durationTimecode(of: subject)
                == TakeRuntime.lengthTimecode(subject.durationSeconds, of: subject))
        }
    }

    /// The marks are filed by FILE NAME, and the transport's own key has to
    /// agree with this one or every mark misses its take.
    @Test func theMarksAreKeyedByFileName() {
        #expect(TakeRuntime.key(take(7)) == "CLIP7.mov")
    }
}
