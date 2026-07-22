import Testing
@testable import CaptureCore

struct TimecodeTests {
    @Test func nonDropFrameNumberRoundTrip() {
        let tc = Timecode(hours: 1, minutes: 23, seconds: 45, frames: 12, fps: 25)
        let restored = Timecode(frameNumber: tc.frameNumber, fps: 25)
        #expect(restored == tc)
    }

    @Test func dropFrameRoundTripSweep() {
        // a round-trip sweep over 24h in ~17-minute steps — catches DF-math errors
        for base in stride(from: 0, to: 24 * 60 * 60 * 30 - 2 * (24 * 60 - 24 * 6), by: 30_007) {
            let tc = Timecode(frameNumber: base, fps: 30, isDropFrame: true)
            #expect(tc.frameNumber == base, "round trip failed for \(tc)")
            // DF never shows frames 00/01 at the start of minutes not divisible by 10
            if tc.seconds == 0 && tc.minutes % 10 != 0 {
                #expect(tc.frames >= 2, "invalid DF label \(tc)")
            }
        }
    }

    @Test func dropFrameMinuteBoundaryIsConsecutive() {
        // 00:00:59;29 → next frame 00:01:00;02
        let before = Timecode(hours: 0, minutes: 0, seconds: 59, frames: 29,
                              fps: 30, isDropFrame: true)
        let after = before.advanced(by: 1)
        #expect(after == Timecode(hours: 0, minutes: 1, seconds: 0, frames: 2,
                                  fps: 30, isDropFrame: true))
        #expect(after.frameNumber - before.frameNumber == 1)
    }

    @Test func tenMinuteBoundaryKeepsFrames() {
        // on minutes divisible by 10 no frames are dropped: 00:09:59;29 → 00:10:00;00
        let before = Timecode(hours: 0, minutes: 9, seconds: 59, frames: 29,
                              fps: 30, isDropFrame: true)
        let after = before.advanced(by: 1)
        #expect(after == Timecode(hours: 0, minutes: 10, seconds: 0, frames: 0,
                                  fps: 30, isDropFrame: true))
    }

    @Test func descriptionFormat() {
        let ndf = Timecode(hours: 9, minutes: 5, seconds: 3, frames: 7, fps: 24)
        #expect(ndf.description == "09:05:03:07")
        let df = Timecode(hours: 9, minutes: 5, seconds: 3, frames: 7, fps: 30, isDropFrame: true)
        #expect(df.description == "09:05:03;07")
        #expect(df.fileNameSafe == "09.05.03.07")
    }
}
