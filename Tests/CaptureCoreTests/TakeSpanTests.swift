import Foundation
import Testing

@testable import CaptureCore

/// Where a take ends — the one number every document about the day carries, and
/// the one the operator reads back over talkback.
///
/// Four surfaces computed it separately (see `TakeSpan`) and the takes panel's
/// copy counted at the NOMINAL frame rate, so on 29.97 and 59.94 drop-frame it
/// ran ahead of the shift report, the report CSV, the Avid log and the EDL by a
/// frame per thousand. Nothing looked wrong: a plausible timecode, a fraction of
/// a second out, on the rate family every US broadcast job shoots.
///
/// So the suite is mostly cross-surface: the same take through the real
/// entry points, and the strings compared with each other rather than with a
/// constant. A shared rule that everything reads can still be WRONG; a rule
/// only some things read is wrong by construction the day one of them changes.
@Suite struct TakeSpanTests {
    private func take(tc: Timecode?, duration: Double) -> Take {
        Take(url: URL(fileURLWithPath: "/tmp/A001C001.mov"),
             scene: "", roll: "A001", takeNumber: 1,
             startTimecode: tc, durationSeconds: duration,
             recordedAt: Date(timeIntervalSince1970: 0))
    }

    /// Start at ten o'clock on `fps`, drop-frame when asked.
    private func start(fps: Int, drop: Bool) -> Timecode {
        Timecode(hours: 10, minutes: 0, seconds: 0, frames: 0, fps: fps,
                 isDropFrame: drop)
    }

    // MARK: - the rate

    /// The measurement the extraction was made for. A drop-frame camera
    /// delivers `fps * 1000/1001` real frames a second, and `frameNumber` is a
    /// count of real frames — so the ten-minute take below is 17 982 frames
    /// long and not 18 000, and the eighteen frames are what the panel used to
    /// add to the take's out point.
    ///
    /// Written as the end TIMECODE rather than as a frame count because the
    /// timecode is what is read off the screen and off the paper.
    /// One row of the measurement: a drop-frame rate, a length, where the take
    /// really ends, and where counting at the nominal rate put it.
    private struct Reading {
        let fps: Int
        let duration: Double
        let end: String
        let nominal: String
    }

    @Test func aDropFrameTakeEndsOnItsRealRateAndNotItsNominalOne() {
        let readings: [Reading] = [
            Reading(fps: 30, duration: 600, end: "10:10:00;00",
                    nominal: "10:10:00;18"),
            Reading(fps: 30, duration: 120, end: "10:01:59;28",
                    nominal: "10:02:00;04"),
            Reading(fps: 30, duration: 60, end: "10:00:59;28",
                    nominal: "10:01:00;02"),
            Reading(fps: 60, duration: 600, end: "10:10:00;00",
                    nominal: "10:10:00;36"),
            Reading(fps: 60, duration: 60, end: "10:00:59;56",
                    nominal: "10:01:00;04"),
        ]
        for row in readings {
            let subject = take(tc: start(fps: row.fps, drop: true),
                               duration: row.duration)
            let span = TakeSpan.of(subject)
            #expect(span.end.description == row.end,
                    "\(row.fps) DF, \(row.duration)s ended \(span.end.description)")
            // and the number it must NOT be: what counting at the nominal rate
            // produces, which is what the takes panel showed
            #expect(span.end.description != row.nominal)
        }
    }

    /// The other half of the same claim, and the reason nobody saw it: at every
    /// rate where the nominal and the real rate are the same number, the wrong
    /// arithmetic gave the right answer. A suite built only on 25 fps fixtures
    /// — which is what the app's demo source generates — is green against the
    /// bug.
    @Test func aNonDropTakeEndsWhereEitherArithmeticWouldPutIt() {
        for fps in [24, 25, 30, 50, 60] {
            for duration in [600.0, 120.0, 33.4, 12.0] {
                let head = start(fps: fps, drop: false)
                let subject = take(tc: head, duration: duration)
                let nominal = Timecode(
                    frameNumber: head.frameNumber
                        + Int((duration * Double(fps)).rounded()),
                    fps: fps, isDropFrame: false)
                #expect(TakeSpan.of(subject).end == nominal,
                        "\(fps) fps, \(duration)s")
            }
        }
    }

    // MARK: - the surfaces agree

    /// The acceptance case. One drop-frame take, and the out point every
    /// document about it states, compared with each other.
    ///
    /// `TakeSpan.of` is what the takes panel's row shows
    /// (`TakeRowTimes.timecodeRange`, in TakeShotKit, which cannot be reached
    /// from here); the other three are read out of the files themselves.
    @Test func everyDocumentStatesTheSameOutPoint() throws {
        let subject = take(tc: start(fps: 30, drop: true), duration: 600)
        let end = TakeSpan.of(subject).end.description

        #expect(try #require(TakeLogExporter.endTimecode(of: subject))
            .description == end)

        // the report CSV's End TC column
        let csv: String = TakeLogExporter.reportCSV(takes: [subject])
        let row: [String] = try #require(csv.split(separator: "\n").last)
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { String($0) }
        let endTCColumn: Int = try #require(
            ShiftReportCSVLabels.english.header.firstIndex(of: "End TC"))
        #expect(row[endTCColumn] == end, "the report CSV says \(row[endTCColumn])")

        // the Avid log's End column. CRLF, so the rows are split on the pair
        // rather than on "\n" — a trailing "\r" would ride into the last cell.
        let ale: String = try #require(ALEExporter.ale(takes: [subject],
                                                       format: nil))
        let aleRow: [String] = try #require(
            ale.components(separatedBy: "\r\n")
                .filter { !$0.isEmpty }.last)
            .split(separator: "\t", omittingEmptySubsequences: false)
            .map { String($0) }
        let aleEnd: Int = try #require(ALEExporter.columns.firstIndex(of: "End"))
        #expect(aleRow[aleEnd] == end, "the ALE says \(aleRow[aleEnd])")

        // the EDL's SOURCE out, which is the take's own rate too
        let edl: String = try #require(EDLExporter.selectsEDL(
            takes: [subject], title: "day", fps: 30))
        #expect(edl.contains(end), "no \(end) in the EDL:\n\(edl)")
    }

    // MARK: - a take with no timecode

    /// A manual take on a source that carries no timecode. The span is
    /// zero-based at the sidecar's own fallback rate, and it SAYS so — the
    /// three consumers want three different things from that fact and each of
    /// them is right (the report prints an em dash, the ALE writes the
    /// zero-based span, the panel shows no range at all).
    @Test func aTakeWithNoTimecodeIsZeroBasedAndSaysSo() {
        let span = TakeSpan.of(take(tc: nil, duration: 12))
        #expect(span.isZeroBased)
        #expect(span.start == TakeLogExporter.fallbackRate)
        #expect(span.start.description == "00:00:00:00")
        #expect(span.end.description == "00:00:12:00")
        // and the shift report still refuses to print it
        #expect(TakeLogExporter.endTimecode(of: take(tc: nil, duration: 12))
            == nil)
        // while a take that HAS one is not zero-based
        #expect(!TakeSpan.of(take(tc: start(fps: 25, drop: false),
                                  duration: 12)).isZeroBased)
    }

    /// A take that finalized with nothing in it. Zero frames, not one — the
    /// EDL clamps its events to a minimum of one frame because a zero-length
    /// CMX event is invalid, and that clamp is deliberately NOT in here: it is
    /// a rule about the edit list's format, not about where the take ended.
    @Test func aZeroLengthTakeEndsWhereItStarted() {
        let head = start(fps: 25, drop: false)
        let span = TakeSpan.of(take(tc: head, duration: 0))
        #expect(span.frames == 0)
        #expect(span.end == head)
    }
}
