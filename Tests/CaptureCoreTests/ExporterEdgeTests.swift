import Foundation
import Testing

@testable import CaptureCore

/// The deliverable exporters at their edges: takes that cross midnight, takes
/// of no length, sessions that changed frame rate at lunch, drop-frame
/// sessions, and the metadata characters that would break the file formats.
/// These are the files handed to post — an edge case here is a conform that
/// fails at 11 pm in another city.
@Suite struct ExporterEdgeTests {
    private func makeTake(name: String, roll: String = "001",
                          tc: Timecode?, duration: Double,
                          comment: String = "",
                          markers: [TakeMarker] = []) -> Take {
        var take = Take(url: URL(fileURLWithPath: "/tmp/\(name)"),
                        scene: "", roll: roll, takeNumber: 1, startTimecode: tc,
                        durationSeconds: duration, recordedAt: Date())
        take.rating = .good
        take.comment = comment
        take.markers = markers
        return take
    }

    // MARK: - midnight

    /// A night shoot's take that rolls through 00:00: the source OUT wraps to
    /// the next day's small timecode, exactly as the timecode track inside the
    /// .mov does — the EDL's source window has to match the media it points
    /// at, or the conform lands a day off. The record side keeps counting.
    @Test func edlSourceOutWrapsAtMidnightLikeTheMediaDoes() throws {
        let take = makeTake(
            name: "night.mov",
            tc: Timecode(hours: 23, minutes: 59, seconds: 58, frames: 0, fps: 25),
            duration: 4)
        let edl = try #require(EDLExporter.selectsEDL(takes: [take], title: "n"))
        #expect(edl.contains(
            "23:59:58:00 00:00:02:00 01:00:00:00 01:00:04:00"))
    }

    /// The ALE's Start/End columns wrap the same way — the two files describe
    /// the same take and must agree on where it ends.
    @Test func aleEndWrapsAtMidnightTheSameWay() throws {
        let take = makeTake(
            name: "night.mov",
            tc: Timecode(hours: 23, minutes: 59, seconds: 58, frames: 0, fps: 25),
            duration: 4)
        let ale = try #require(ALEExporter.ale(takes: [take]))
        let row = try #require(ale.components(separatedBy: "\r\n")
            .first { $0.hasPrefix("night.mov") })
        #expect(row.contains("23:59:58:00\t00:00:02:00"))
    }

    // MARK: - degenerate lengths

    /// A zero-length take still cuts one frame: CMX events with OUT == IN are
    /// invalid, and a take the operator can see in the list has to reach the
    /// timeline, however short the camera made it.
    @Test func aZeroDurationTakeStillCutsOneFrame() throws {
        let takes = [
            makeTake(name: "blip.mov",
                     tc: Timecode(hours: 10, minutes: 0, seconds: 0, frames: 0,
                                  fps: 25),
                     duration: 0),
            makeTake(name: "next.mov",
                     tc: Timecode(hours: 11, minutes: 0, seconds: 0, frames: 0,
                                  fps: 25),
                     duration: 1),
        ]
        let edl = try #require(EDLExporter.selectsEDL(takes: takes, title: "t"))
        #expect(edl.contains(
            "10:00:00:00 10:00:00:01 01:00:00:00 01:00:00:01"))
        // and the record timeline continues from that one frame, gaplessly
        #expect(edl.contains("01:00:00:01 01:00:01:01"))
    }

    // MARK: - mixed rates

    /// A day that changed frame rate at lunch: each event's SOURCE runs on its
    /// own take's clock while the record side stays on the session master —
    /// counting the 24 fps take in master frames is how a conform lands a
    /// frame early on every cut after lunch.
    @Test func mixedRateTakesKeepTheirOwnSourceClocks() throws {
        let takes = [
            makeTake(name: "morning.mov",
                     tc: Timecode(hours: 10, minutes: 0, seconds: 0, frames: 0,
                                  fps: 25),
                     duration: 2),
            makeTake(name: "afternoon.mov",
                     tc: Timecode(hours: 1, minutes: 0, seconds: 0, frames: 0,
                                  fps: 24),
                     duration: 1),
        ]
        let edl = try #require(EDLExporter.selectsEDL(takes: takes, title: "t"))
        // one second of the 24 fps take is 24 source frames but 25 record ones
        #expect(edl.contains(
            "01:00:00:00 01:00:01:00 01:00:02:00 01:00:03:00"))
        // the ALE states each take's own rate in its FPS column
        let ale = try #require(ALEExporter.ale(takes: takes))
        let rows = ale.components(separatedBy: "\r\n")
        #expect(try #require(rows.first { $0.hasPrefix("morning.mov") })
            .contains("\t25\t"))
        #expect(try #require(rows.first { $0.hasPrefix("afternoon.mov") })
            .contains("\t24\t"))
    }

    // MARK: - drop frame

    /// A 29.97 DF session: the FCM line says DROP FRAME and every timecode
    /// carries the semicolon — an FCM that lies about the counting mode shifts
    /// the whole conform by the dropped frames.
    @Test func aDropFrameSessionDeclaresItselfInTheFCM() throws {
        let take = makeTake(
            name: "df.mov",
            tc: Timecode(hours: 10, minutes: 0, seconds: 0, frames: 0,
                         fps: 30, isDropFrame: true),
            duration: 2)
        let edl = try #require(EDLExporter.selectsEDL(takes: [take], title: "t"))
        #expect(edl.contains("FCM: DROP FRAME"))
        // 2 s at 29.97 real fps is 60 frames on both clocks
        #expect(edl.contains(
            "10:00:00;00 10:00:02;00 01:00:00;00 01:00:02;00"))
    }

    // MARK: - the characters that break the formats

    /// A two-line comment is one comment line in the EDL: a newline inside
    /// `* COMMENT:` would inject an arbitrary EDL statement.
    @Test func commentNewlinesAreFlattenedIntoOneEDLLine() throws {
        let take = makeTake(
            name: "c.mov",
            tc: Timecode(hours: 10, minutes: 0, seconds: 0, frames: 0, fps: 25),
            duration: 1, comment: "great energy\nuse this one")
        let edl = try #require(EDLExporter.selectsEDL(takes: [take], title: "t"))
        #expect(edl.contains("* COMMENT: great energy use this one"))
    }

    /// A marker with no note and no timecode text still gets a locator name —
    /// Resolve drops a `* LOC:` whose name field is empty.
    @Test func aNamelessMarkerIsStillALocator() throws {
        let take = makeTake(
            name: "m.mov",
            tc: Timecode(hours: 10, minutes: 0, seconds: 0, frames: 0, fps: 25),
            duration: 4,
            markers: [TakeMarker(seconds: 1)])
        let edl = try #require(EDLExporter.selectsEDL(takes: [take], title: "t"))
        #expect(edl.contains("* LOC: 01:00:01:00 ORANGE MARKER"))
    }

    /// A take with no roll gets a counter reel — and the SAME counter reel in
    /// both files, because the Tape column is how the ALE joins up with the
    /// EDL's conform.
    @Test func anEmptyRollFallsBackToTheSameCounterReelInBothFiles() throws {
        let take = makeTake(
            name: "r.mov", roll: "",
            tc: Timecode(hours: 10, minutes: 0, seconds: 0, frames: 0, fps: 25),
            duration: 1)
        let edl = try #require(EDLExporter.selectsEDL(takes: [take], title: "t"))
        #expect(edl.contains("001  TS001    V     C"))
        let ale = try #require(ALEExporter.ale(takes: [take]))
        #expect(ale.contains("r.mov\tTS001\t"))
    }
}
