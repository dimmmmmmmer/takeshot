import Foundation
import Testing

@testable import CaptureCore

/// **A marked take reaches a timeline as the part that was marked, with the
/// whole file still behind it** (owner: "так а ты просто в самом таймлайне клип
/// кидай по ин ауту но сорс пускай остается полным. монтажер просто если что
/// сможет размотать тейк по началу или по концу").
///
/// The in/out an operator sets during review used to be a loop range for
/// watching and nothing else: the shift report counted it, and all three
/// timelines wrote the take end to end. That is the wrong half of the job —
/// the operator marked the part that is good, and the timeline is where a
/// selection belongs. What it must NOT do is throw the rest away, because an
/// editor who needs a frame of handle has nowhere to get it from.
///
/// So every format states two lengths now, and this suite is mostly about the
/// two of them staying different: the clip is the marked part, the media is
/// the whole take. `TakeSpan.marked` and the EDL are here; the two XML writers
/// are next door in `TimelineTrimXMLTests`.
@Suite struct TimelineTrimTests {
    /// Ten o'clock, 25 fps, ten seconds — 250 frames, so a mark at 2 s is
    /// frame 50 and every number below can be read by eye.
    private func take(_ name: String = "A001C001.mov", seconds: Double = 10,
                      tc: Timecode? = Timecode(hours: 10, minutes: 0,
                                               seconds: 0, frames: 0, fps: 25),
                      markers: [TakeMarker] = []) -> Take {
        var take = Take(url: URL(fileURLWithPath: "/tmp/\(name)"),
                        scene: "", roll: "001", takeNumber: 1, startTimecode: tc,
                        durationSeconds: seconds, recordedAt: Date())
        take.rating = .good
        take.markers = markers
        return take
    }

    private func marks(_ name: String = "A001C001.mov", in start: Double?,
                       out end: Double?) -> [String: ClipRange] {
        [name: ClipRange(inPoint: start, outPoint: end)]
    }

    // MARK: - the span

    /// The span of the marked part, on the take's own timebase: the in point
    /// advances the start and the window sets the length.
    @Test func aMarkedSpanStartsAtTheInPointAndRunsTheWindow() {
        let subject = take()
        let span = TakeSpan.marked(subject,
                                   range: ClipRange(inPoint: 2, outPoint: 6))
        #expect(span.start.description == "10:00:02:00")
        #expect(span.frames == 100)
        #expect(span.end.description == "10:00:06:00")
        #expect(span.offset(from: .of(subject)) == 50)
    }

    /// **The whole point of the change being opt-in.** Every one of the four
    /// ways a mark says nothing — absent, empty, inverted, covering the whole
    /// take — comes back as the unmarked span exactly, so a day nobody marked
    /// produces the documents it always produced.
    @Test func aMarkThatSelectsNothingLeavesTheSpanWhole() {
        let subject = take()
        let whole = TakeSpan.of(subject)
        let nothings: [ClipRange?] = [
            nil,
            ClipRange.unset,
            ClipRange(inPoint: 6, outPoint: 2),
            ClipRange(inPoint: 4, outPoint: 4),
            ClipRange(inPoint: 0, outPoint: 10),
        ]
        for range in nothings {
            let span = TakeSpan.marked(subject, range: range)
            #expect(span == whole, "\(String(describing: range)) narrowed it")
            #expect(span.offset(from: whole) == 0)
        }
    }

    /// A window that rounds to nothing is still a clip. An NLE drops a
    /// zero-length clip from the timeline without saying so, which is the
    /// worst way for a circled take to go missing.
    @Test func aWindowShorterThanAFrameIsStillOneFrame() {
        let span = TakeSpan.marked(take(),
                                   range: ClipRange(inPoint: 2,
                                                    outPoint: 2.001))
        #expect(span.frames == 1)
    }

    // MARK: - the EDL

    /// The source side names the marked part, and the RECORD side advances by
    /// it: the second event butts against the first at 01:00:04:00, not at
    /// 01:00:10:00 where an untrimmed take would have left it.
    @Test func theEDLCutsTheEventAndClosesTheGap() throws {
        let first = take("A.mov")
        let second = take("B.mov", tc: Timecode(hours: 11, minutes: 0,
                                                seconds: 0, frames: 0, fps: 25))
        let edl = try #require(EDLExporter.selectsEDL(
            takes: [first, second], title: "t",
            ranges: marks("A.mov", in: 2, out: 6)))
        #expect(edl.contains(
            "001  001      V     C        10:00:02:00 10:00:06:00 "
                + "01:00:00:00 01:00:04:00"))
        #expect(edl.contains(
            "002  001      V     C        11:00:00:00 11:00:10:00 "
                + "01:00:04:00 01:00:14:00"))
    }

    /// **The same day with no marks is the EDL it always was.** Compared
    /// against the exporter's own unmarked output rather than against a
    /// constant: a shared rule can be wrong, but a rule only the marked path
    /// reads is wrong by construction the day one of them changes.
    @Test func anUnmarkedDayIsTheEDLItAlwaysWas() throws {
        let takes = [take("A.mov"),
                     take("B.mov", seconds: 4,
                          markers: [TakeMarker(seconds: 1,
                                               timecodeText: "10:00:01:00")])]
        let before = try #require(EDLExporter.selectsEDL(takes: takes, title: "t"))
        let after = try #require(EDLExporter.selectsEDL(
            takes: takes, title: "t", ranges: marks("A.mov", in: nil, out: nil)))
        #expect(before == after)
    }

    /// Locators move back by the head and the ones outside the window go.
    ///
    /// A marker at 1 s is before an in point at 2 s: it is not on this event
    /// at all, and written from the take's first frame it would land a whole
    /// two seconds ahead of where it belongs — on the event before, or off the
    /// front of the timeline.
    @Test func locatorsFollowTheTrimAndTheOnesOutsideAreDropped() throws {
        let subject = take("A.mov", markers: [
            TakeMarker(seconds: 1, timecodeText: "before"),
            TakeMarker(seconds: 3, timecodeText: "inside"),
            TakeMarker(seconds: 9, timecodeText: "after"),
        ])
        let edl = try #require(EDLExporter.selectsEDL(
            takes: [subject], title: "t", ranges: marks("A.mov", in: 2, out: 6)))
        #expect(edl.contains("* LOC: 01:00:01:00 YELLOW inside"))
        #expect(!edl.contains("before"))
        #expect(!edl.contains("after"))
    }

    /// A marker exactly on the out point is OUTSIDE: the window is
    /// half-open, the way every other length in this app is counted, and a
    /// locator one frame past the end of an event is one the next event owns.
    @Test func theWindowIsHalfOpenAtTheOutPoint() throws {
        let subject = take("A.mov", markers: [
            TakeMarker(seconds: 2, timecodeText: "on the in point"),
            TakeMarker(seconds: 6, timecodeText: "on the out point"),
        ])
        let edl = try #require(EDLExporter.selectsEDL(
            takes: [subject], title: "t", ranges: marks("A.mov", in: 2, out: 6)))
        #expect(edl.contains("on the in point"))
        #expect(!edl.contains("on the out point"))
    }

    /// **A hundred seconds of 23.976 is 2500 frames of a 25 fps timeline, not
    /// 2498.**
    ///
    /// The record side converts the take's own frames back to seconds and then
    /// into the sequence's, and which rate it divides by is the whole
    /// question: a 23.976 take numbered at 24 NON-DROP counts 23.976 frames a
    /// second while its timecode reads 24, and dividing by the timecode's
    /// loses one frame in a thousand. It ACCUMULATES down the event list, so
    /// the last reel of a day is further out than the first, and it is the
    /// same 1000/1001 `TakeSpan` was extracted to stop four surfaces getting
    /// wrong — arriving from the other side.
    ///
    /// A hundred seconds and not four, deliberately: at four seconds both
    /// answers round to 100 frames and the test below passes either way. This
    /// is the length where the two part company.
    @Test func aLongTakeAtAnNTSCRateAdvancesTheTimelineByRealSeconds() throws {
        var slow = take("A.mov", seconds: 100,
                        tc: Timecode(hours: 10, minutes: 0, seconds: 0,
                                     frames: 0, fps: 24))
        slow.frameRate = 23.976
        let span = TakeSpan.of(slow)
        #expect(span.frames == 2398, "the take is \(span.frames) of its own frames")
        #expect(abs(span.rate - 23.976) < 0.0001,
                "the span counts at \(span.rate), not the take's own rate")

        let edl = try #require(EDLExporter.selectsEDL(
            takes: [slow, take("B.mov", seconds: 4)], title: "t", fps: 25))
        // 100 s at 25 is 2500 frames — 01:00:00:00 + 00:01:40:00
        #expect(edl.contains("01:00:00:00 01:01:40:00"),
                "the first event is not a hundred seconds long")
        #expect(edl.contains("002  001      V     C        10:00:00:00 "
            + "10:00:04:00 01:01:40:00 01:01:44:00"),
                "the second event does not butt against the first")
    }

    /// **A mixed-rate day.** The source side counts in the TAKE's frames and
    /// the record side in the sequence's, and a trim has to convert between
    /// them — a 23.976 take marked to four seconds advances a 25 fps timeline
    /// by 100 frames, not by the 96 its own rate counts.
    @Test func aTrimAtAnotherRateAdvancesTheSequenceCorrectly() throws {
        var slow = take("A.mov", tc: Timecode(hours: 10, minutes: 0, seconds: 0,
                                              frames: 0, fps: 24))
        slow.frameRate = 23.976
        let edl = try #require(EDLExporter.selectsEDL(
            takes: [slow, take("B.mov")], title: "t", fps: 25,
            ranges: marks("A.mov", in: 2, out: 6)))
        // 4 s of a 23.976 take is 96 of ITS frames, numbered at 24; the same
        // 4 s is 100 of the sequence's, which is what the record advances by.
        #expect(edl.contains("001  001      V     C        10:00:02:00 "
            + "10:00:06:00 01:00:00:00 01:00:04:00"))
        #expect(edl.contains("002  001      V     C        10:00:00:00 "
            + "10:00:10:00 01:00:04:00 01:00:14:00"))
    }
}
