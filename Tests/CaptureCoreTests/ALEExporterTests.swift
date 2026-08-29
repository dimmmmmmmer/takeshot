import Foundation
import Testing

@testable import CaptureCore

/// The Avid Log Exchange file, byte for byte.
///
/// Golden expectations rather than "contains": this file is parsed by Media
/// Composer, which splits rows on tabs and trusts the count. A stray tab, a
/// column in the wrong order or a quoted field the CSV exporter would have
/// produced all import as a bin full of clips with their metadata one cell out
/// — and nobody notices until the conform.
@Suite struct ALEExporterTests {
    /// The review state a take picks up afterwards is set in the closure rather
    /// than through six more parameters — the exporter reads a Take, not a
    /// parameter list, and the golden rows below are easier to match to their
    /// input this way.
    private func makeTake(name: String, roll: String, tc: Timecode?,
                          duration: Double,
                          _ configure: (inout Take) -> Void = { _ in }) -> Take {
        var take = Take(url: URL(fileURLWithPath: "/tmp/\(name)"),
                        scene: "", roll: roll, takeNumber: 1,
                        startTimecode: tc, durationSeconds: duration,
                        recordedAt: Date(timeIntervalSince1970: 0))
        configure(&take)
        return take
    }

    /// The shift the golden file below is built from: a circled take at 25 fps,
    /// an unrated one on a 29.97 drop-frame camera, and a rejected one whose
    /// comment carries both a comma and a tab.
    private var shift: [Take] {
        [makeTake(name: "A001C001.mov", roll: "A001",
                  tc: Timecode(hours: 10, minutes: 0, seconds: 0, frames: 0,
                               fps: 25),
                  duration: 4) {
             // a fully slated take: the creative columns come from the slate,
             // and the Take column is the slate's number, not the clip's
             $0.slate = SlateMetadata(scene: "12", shot: 2, take: 4)
             $0.rating = .good
             $0.comment = "hero"
             $0.logDescription = "wide on the door"
         },
         makeTake(name: "B002C003.mov", roll: "B002",
                  tc: Timecode(hours: 1, minutes: 0, seconds: 0, frames: 0,
                               fps: 30, isDropFrame: true),
                  duration: 2) {
             // a scene with no shot letter and no slated take: the clip
             // counter is what the Take column falls back to
             $0.scene = "12A"
             $0.takeNumber = 3
         },
         makeTake(name: "C.mov", roll: "",
                  tc: Timecode(hours: 10, minutes: 0, seconds: 10, frames: 0,
                               fps: 25),
                  duration: 1) {
             $0.takeNumber = 7
             $0.rating = .bad
             $0.comment = "wide, then\ttight"
         }]
    }

    private static let hd = CaptureFormat(width: 1920, height: 1080,
                                          frameRate: 25, timecodeFPS: 25,
                                          name: "1080p25")

    /// The whole file, exactly.
    @Test func theFileIsExactlyThis() throws {
        let ale = try #require(ALEExporter.ale(takes: shift, format: Self.hd))
        let expected = [
            "Heading",
            "FIELD_DELIM\tTABS",
            "VIDEO_FORMAT\t1080",
            "AUDIO_FORMAT\t48kHz",
            "FPS\t25",
            "",
            "Column",
            "Name\tTape\tStart\tEnd\tDuration\tFPS\tTake\tScene\tShot\tGood Take"
                + "\tComments\tDescription",
            "",
            "Data",
            "A001C001.mov\tA001\t10:00:00:00\t10:00:04:00\t00:00:04:00\t25\t4\t12"
                + "\t2\ttrue\thero\twide on the door",
            // drop-frame: the semicolon separator, and 2 s is 60 real frames
            "B002C003.mov\tB002\t01:00:00;00\t01:00:02;00\t00:00:02;00\t29.97\t3\t12A"
                + "\t\t\t\t",
            // no roll — the EDL's counter reel; the tab in the comment became a
            // space, the comma stayed a comma. The rejected-take marker is the
            // Comments column's own, shared with the Resolve CSV: "Bad", where
            // every build before the rename wrote "NG".
            "C.mov\tTS003\t10:00:10:00\t10:00:11:00\t00:00:01:00\t25\t7\t\t"
                + "\tfalse\tBad: wide, then tight\t",
        ].joined(separator: "\r\n") + "\r\n"
        #expect(ale == expected)
    }

    /// CRLF, everywhere, including the last line — stated as its own check
    /// because a golden string is easy to read past a line ending in.
    @Test func everyLineEndsCRLF() throws {
        let ale = try #require(ALEExporter.ale(takes: shift, format: Self.hd))
        #expect(ale.hasSuffix("\r\n"))
        #expect(ale.components(separatedBy: "\n").count
                == ale.components(separatedBy: "\r\n").count,
                "a bare LF got in")
    }

    @Test func anEmptyShiftExportsNothing() {
        #expect(ALEExporter.ale(takes: [], format: Self.hd) == nil)
    }

    /// The Tape column is the EDL's reel, not a second opinion about it. A roll
    /// longer than the 8 characters CMX allows is truncated the same way in
    /// both files, or the conform and the bin stop referring to the same roll.
    @Test func theTapeColumnIsTheSameReelTheEDLWrites() throws {
        let take = makeTake(name: "A.mov", roll: "A001 LONGNAME",
                            tc: Timecode(hours: 10, minutes: 0, seconds: 0,
                                         frames: 0, fps: 25),
                            duration: 1) { $0.rating = .good }
        let ale = try #require(ALEExporter.ale(takes: [take]))
        let tape = try #require(ale.components(separatedBy: "\r\n")
            .last { $0.hasPrefix("A.mov") })
            .components(separatedBy: "\t")[1]
        #expect(tape == "A001_LON")
        let edl = try #require(EDLExporter.selectsEDL(takes: [take], title: "t"))
        #expect(edl.contains("001  A001_LON V     C"))
    }

    /// VIDEO_FORMAT is an Avid enumeration, not a raster: 2K DCI is 1080 high
    /// and is still CUSTOM, and a shift exported with no capture device
    /// attached says CUSTOM rather than guessing HD.
    @Test func videoFormatIsTheAvidEnumerationNotTheFrameSize() throws {
        func heading(_ format: CaptureFormat?) throws -> String {
            let ale = try #require(ALEExporter.ale(takes: shift, format: format))
            return try #require(ale.components(separatedBy: "\r\n")
                .first { $0.hasPrefix("VIDEO_FORMAT") })
        }
        func size(_ width: Int, _ height: Int) -> CaptureFormat {
            CaptureFormat(width: width, height: height, frameRate: 25,
                          timecodeFPS: 25, name: "\(height)")
        }
        #expect(try heading(size(1280, 720)) == "VIDEO_FORMAT\t720")
        #expect(try heading(size(720, 576)) == "VIDEO_FORMAT\tPAL")
        #expect(try heading(size(720, 486)) == "VIDEO_FORMAT\tNTSC")
        #expect(try heading(size(2048, 1080)) == "VIDEO_FORMAT\tCUSTOM")
        #expect(try heading(size(3840, 2160)) == "VIDEO_FORMAT\tCUSTOM")
        #expect(try heading(nil) == "VIDEO_FORMAT\tCUSTOM")
    }

    /// The heading rate is the MEASURED one when a signal is known: 23.976 is
    /// not expressible as a nominal timecode rate, so deriving it from the
    /// take's timecode would round the whole project to 24.
    @Test func theHeadingRateComesFromTheSignalWhenThereIsOne() throws {
        let format = CaptureFormat(width: 1920, height: 1080,
                                   frameRate: 24000.0 / 1001, timecodeFPS: 24,
                                   name: "1080p23.98")
        let ale = try #require(ALEExporter.ale(takes: shift, format: format))
        #expect(ale.contains("FPS\t23.976"))
    }

    /// With no signal the first take's own timecode sets the rate, drop-frame
    /// included — 30 DF numbering runs at 29.97 real frames a second.
    @Test func theHeadingRateFallsBackToTheFirstTakesTimecode() throws {
        let ale = try #require(ALEExporter.ale(takes: Array(shift.dropFirst())))
        #expect(ale.contains("FPS\t29.97"))
    }

    /// A take recorded with no timecode at all is written from zero rather than
    /// blank: a blank Start imports as a clip with no position AND loses the
    /// length, where zero-based cells at least carry the duration across.
    @Test func aTakeWithNoTimecodeIsWrittenFromZero() throws {
        let take = makeTake(name: "manual.mov", roll: "X", tc: nil, duration: 3)
        let ale = try #require(ALEExporter.ale(takes: [take]))
        #expect(ale.contains(
            "manual.mov\tX\t00:00:00:00\t00:00:03:00\t00:00:03:00\t25\t1\t\t\t"))
    }

    /// Newlines cannot survive in a row: the reader splits records on them, so
    /// a two-line comment would become a second clip with nine empty columns.
    @Test func aNewlineInACommentBecomesASpace() throws {
        let take = makeTake(name: "A.mov", roll: "R",
                            tc: Timecode(hours: 10, minutes: 0, seconds: 0,
                                         frames: 0, fps: 25),
                            duration: 1) { $0.comment = "line one\nline two" }
        let ale = try #require(ALEExporter.ale(takes: [take]))
        #expect(ale.contains("line one line two"))
        // 10 structural lines + one data row, and the empty tail of the final
        // terminator — a comment that split would add a twelfth
        #expect(ale.components(separatedBy: "\r\n").count == 12)
    }
}
