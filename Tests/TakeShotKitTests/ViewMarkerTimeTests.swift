import CaptureCore
import Testing

@testable import TakeShotKit

/// **A marker reads in the same clock as the transport above it** (owner:
/// "посмотри на таймкоды тейка и таймкоды маркера", with a list saying
/// 00:00:02:03 beside a badge saying 12:19:57:13).
///
/// The two are not the same value by accident: the sidecar has no anchor for a
/// clip that is not a take, so what is STORED has to stay an offset from that
/// clip's zero. What the screen shows is the clip's own start plus that
/// offset, which is what every other readout in the window is counting.
@Suite struct ViewMarkerTimeTests {
    private let start = Timecode(hours: 12, minutes: 19, seconds: 55,
                                 frames: 0, fps: 25)

    /// A take's marker is already absolute and is shown as it is.
    @Test func aTakesMarkerIsShownAsItIsStored() {
        let marker = TakeMarker(seconds: 2.12, timecodeText: "12:19:57:03")
        #expect(MarkerDisplayTime.text(for: marker, clipStart: start,
                                       isTake: true) == "12:19:57:03")
    }

    /// **A non-take's marker is shown in the clip's own clock**, not as the
    /// offset the file keeps.
    @Test func aForeignClipsMarkerIsShownInTheClipsOwnClock() {
        let marker = TakeMarker(seconds: 2.12, timecodeText: "00:00:02:03")
        let shown = MarkerDisplayTime.text(for: marker, clipStart: start,
                                           isTake: false)
        #expect(shown == "12:19:57:03", """
            a marker two seconds into a clip starting at \(start.description) \
            was shown as \(shown)
            """)
        #expect(shown != marker.timecodeText, """
            the row still prints the stored offset
            """)
    }

    /// …and a clip with no timecode at all keeps the offset, because there is
    /// nothing to add it to. The two cases are told apart by the anchor and
    /// not by a flag somebody has to remember to set.
    @Test func aClipWithNoTimecodeKeepsTheOffset() {
        let marker = TakeMarker(seconds: 2.12, timecodeText: "00:00:02:03")
        #expect(MarkerDisplayTime.text(for: marker, clipStart: nil,
                                       isTake: false) == "00:00:02:03")
    }

    /// A marker with no text at all — one restored from an old sidecar's
    /// Seconds column — still reads as a position rather than as a blank.
    @Test func aMarkerWithNoTextStillReadsAsATime() {
        let marker = TakeMarker(seconds: 65)
        #expect(MarkerDisplayTime.text(for: marker, clipStart: nil,
                                       isTake: true) == "1:05")
    }
}
