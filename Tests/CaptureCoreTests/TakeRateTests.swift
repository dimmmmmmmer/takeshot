import Foundation
import Testing

@testable import CaptureCore

/// **A 23.976 take is counted at 23.976, not 24.**
///
/// A timecode numbers frames at 24 or 30 and says nothing about whether the
/// clock behind it runs at 1000/1001 of that. Drop-frame flags the 29.97 case;
/// nothing flagged 23.976 or 29.97 non-drop, and `realRate(of:)` read those as
/// exactly 24 and 30 — so every OUT point, duration-in-frames, ALE FPS column
/// and marker position on such a take ran a frame ahead every 41 seconds. The
/// take carries its real rate now (from the capture format at open, stamped
/// into the .mov as `com.takeshot.framerate`, read back on restore).
@Suite struct TakeRateTests {
    private func take(rate: Double?, fps: Int = 24, dropFrame: Bool = false,
                      seconds: Double = 100) -> Take {
        Take(url: URL(fileURLWithPath: "/tmp/A001C01.mov"), scene: "",
             roll: "001", takeNumber: 1,
             startTimecode: Timecode(hours: 10, minutes: 0, seconds: 0, frames: 0,
                                     fps: fps, isDropFrame: dropFrame),
             durationSeconds: seconds, recordedAt: Date(timeIntervalSince1970: 0),
             frameRate: rate)
    }

    @Test func aHundredSecondsAt23976IsNot2400Frames() {
        let span = TakeSpan.of(take(rate: 23.976))
        #expect(span.frames == 2398, "counted \(span.frames) frames — 24 fps would say 2400")
        #expect(TakeLogExporter.realRate(for: take(rate: 23.976)) == 23.976)
    }

    /// And 29.97 NON-drop — the case drop-frame never flagged.
    @Test func twentyNineNinetySevenNonDropIsCountedAsSuch() {
        let span = TakeSpan.of(take(rate: 29.97, fps: 30))
        #expect(span.frames == 2997, "counted \(span.frames) frames — 30 fps would say 3000")
    }

    /// Drop-frame was already right and stays right: the flag is the rate.
    @Test func dropFrameIsUnchanged() {
        let flagged = TakeSpan.of(take(rate: nil, fps: 30, dropFrame: true))
        let stated = TakeSpan.of(take(rate: 29.97, fps: 30, dropFrame: true))
        #expect(flagged.frames == 2997)
        #expect(stated.frames == flagged.frames)
    }

    /// A take that cannot say its rate — an older file, no track to ask — is
    /// counted the way it always was, on the timecode's own reading.
    @Test func noRateFallsBackToTheTimecodesReading() {
        let span = TakeSpan.of(take(rate: nil))
        #expect(span.frames == 2400)
    }

    /// A marker on a 23.976 take lands on the frame it was set on, both ways.
    @Test func aMarkerRoundTripsOnTheTakesOwnRate() {
        let t = take(rate: 23.976)
        // 41.708 s in is frame 1000 at 23.976 (and would be 1001 at 24)
        let marker = TakeMarker(seconds: 1000 / 23.976, timecodeText: "",
                                color: "red", note: "")
        let text = TakeLogExporter.markerTimecode(of: marker, in: t)
        #expect(text == "10:00:41:16", "marker written at \(text)")
        let back = TakeLogExporter.markers(
            [TakeLogExporter.MarkerRow(timecodeText: text, color: "red", note: "")],
            of: t)
        let seconds = try? #require(back.first?.seconds)
        #expect(abs((seconds ?? 0) - 1000 / 23.976) < 0.001,
                "read back at \(seconds as Any) s")
    }
}
