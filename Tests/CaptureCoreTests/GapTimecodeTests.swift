import Testing
@testable import CaptureCore

/// The parts of `Timecode` that `TimecodeTests` leaves open: 59.94 drop-frame
/// (only 29.97 was swept), the midnight `dayFrames` wrap that `RecDetector` and
/// the pre-roll TC shift both depend on, and the text parser.
///
/// A drift here is silent and expensive: takes come out labelled a frame or two
/// off the camera original, and nobody notices until the edit.
struct GapTimecodeTests {
    // MARK: - 59.94 drop-frame

    /// 60 DF drops 4 frames a minute, not 2. The whole day is swept for a
    /// round trip so an off-by-one in `framesPer10Minutes` cannot hide in a
    /// range the 30 fps sweep happens not to reach.
    @Test func sixtyFPSDropFrameRoundTripSweep() {
        let day = Timecode.dayFrames(fps: 60, isDropFrame: true)
        for base in stride(from: 0, to: day, by: 60_013) {
            let tc = Timecode(frameNumber: base, fps: 60, isDropFrame: true)
            #expect(tc.frameNumber == base, "round trip failed for \(tc)")
            // DF never labels frames 00-03 at the top of a minute that is not
            // divisible by 10
            if tc.seconds == 0 && tc.minutes % 10 != 0 {
                #expect(tc.frames >= 4, "invalid 60 DF label \(tc)")
            }
        }
    }

    @Test func sixtyFPSDropFrameMinuteBoundarySkipsFourFrames() {
        // 00:00:59;59 → next frame 00:01:00;04
        let before = Timecode(hours: 0, minutes: 0, seconds: 59, frames: 59,
                              fps: 60, isDropFrame: true)
        let after = before.advanced(by: 1)
        #expect(after == Timecode(hours: 0, minutes: 1, seconds: 0, frames: 4,
                                  fps: 60, isDropFrame: true))
        #expect(after.frameNumber - before.frameNumber == 1)
    }

    @Test func sixtyFPSTenMinuteBoundaryDropsNothing() {
        let before = Timecode(hours: 0, minutes: 9, seconds: 59, frames: 59,
                              fps: 60, isDropFrame: true)
        #expect(before.advanced(by: 1)
            == Timecode(hours: 0, minutes: 10, seconds: 0, frames: 0,
                        fps: 60, isDropFrame: true))
    }

    // MARK: - the day length

    /// The numbers `preRollShiftedTimecode` and `RecDetector.movement` add and
    /// subtract to cross midnight. 30 DF is the value quoted in Timecode's own
    /// documentation; the rest follow the same rule.
    @Test func dayFramesMatchesTheRateAndDropFlag() {
        #expect(Timecode.dayFrames(fps: 24, isDropFrame: false) == 24 * 86_400)
        #expect(Timecode.dayFrames(fps: 25, isDropFrame: false) == 25 * 86_400)
        #expect(Timecode.dayFrames(fps: 30, isDropFrame: false) == 30 * 86_400)
        #expect(Timecode.dayFrames(fps: 30, isDropFrame: true) == 2_589_408)
        #expect(Timecode.dayFrames(fps: 60, isDropFrame: true) == 5_178_816)
        // 25 fps has no drop-frame variant — the flag must not shorten the day
        #expect(Timecode.dayFrames(fps: 25, isDropFrame: true) == 25 * 86_400)
    }

    /// The DeckLink bridge hands the pipeline timecodes with `fps: 0` (it does
    /// not know the rate; the pipeline fills it from the detected format).
    /// `dayFrames` is reached with that value through `RecDetector.movement`,
    /// so it has to survive it.
    @Test func dayFramesSurvivesAnUnknownRate() {
        #expect(Timecode.dayFrames(fps: 0, isDropFrame: false) == 86_400)
        #expect(Timecode.dayFrames(fps: -5, isDropFrame: true) == 86_400)
    }

    /// Midnight is one frame after the last frame of the day, and the delta
    /// across it is exactly the `1 - dayFrames` case `RecDetector` special-cases
    /// as "advancing" rather than a discontinuity that would split the take.
    @Test func midnightWrapIsOneFrameForward() {
        for (fps, dropFrame) in [(25, false), (30, true), (60, true), (24, false)] {
            let day = Timecode.dayFrames(fps: fps, isDropFrame: dropFrame)
            let last = Timecode(frameNumber: day - 1, fps: fps, isDropFrame: dropFrame)
            #expect(last.hours == 23 && last.minutes == 59 && last.seconds == 59,
                    "last frame of the day is \(last) at \(fps)")
            let wrapped = last.advanced(by: 1)
            #expect(wrapped == Timecode(hours: 0, minutes: 0, seconds: 0, frames: 0,
                                        fps: fps, isDropFrame: dropFrame),
                    "wrap at \(fps) produced \(wrapped)")
            #expect(wrapped.frameNumber - last.frameNumber == 1 - day)
        }
    }

    /// The pre-roll shift subtracts frames from the take's start TC and adds a
    /// day back when it goes negative. A take started seconds after midnight
    /// must land at the end of the previous day, not clamp to zero.
    @Test func preRollShiftAcrossMidnightLandsAtTheEndOfTheDay() {
        let start = Timecode(hours: 0, minutes: 0, seconds: 0, frames: 2,
                             fps: 30, isDropFrame: true)
        let day = Timecode.dayFrames(fps: 30, isDropFrame: true)
        var shifted = start.frameNumber - 5
        #expect(shifted < 0)
        shifted += day
        let result = Timecode(frameNumber: shifted, fps: 30, isDropFrame: true)
        #expect(result == Timecode(hours: 23, minutes: 59, seconds: 59, frames: 27,
                                   fps: 30, isDropFrame: true))
    }

    // MARK: - text parsing

    @Test func parsesBothSeparatorsAndInfersDropFrame() throws {
        let ndf = try #require(Timecode(text: "01:23:45:12", fps: 25))
        #expect(ndf == Timecode(hours: 1, minutes: 23, seconds: 45, frames: 12, fps: 25))
        #expect(!ndf.isDropFrame)

        let df = try #require(Timecode(text: "10:00:00;02", fps: 30))
        #expect(df.isDropFrame)
        #expect(df == Timecode(hours: 10, minutes: 0, seconds: 0, frames: 2,
                               fps: 30, isDropFrame: true))
    }

    /// Marker positions are re-anchored by parsing back the text a `Timecode`
    /// printed, so the two must be exact inverses — including the drop-frame
    /// separator.
    @Test func descriptionRoundTripsThroughTheParser() throws {
        for tc in [Timecode(hours: 0, minutes: 0, seconds: 0, frames: 0, fps: 25),
                   Timecode(hours: 23, minutes: 59, seconds: 59, frames: 29,
                            fps: 30, isDropFrame: true),
                   Timecode(hours: 9, minutes: 5, seconds: 3, frames: 7, fps: 24)] {
            let parsed = try #require(Timecode(text: tc.description, fps: tc.fps))
            #expect(parsed == tc, "\(tc.description) parsed back as \(parsed)")
        }
    }

    @Test func rejectsMalformedText() {
        #expect(Timecode(text: "", fps: 25) == nil)
        #expect(Timecode(text: "10:00:00", fps: 25) == nil)          // too few fields
        #expect(Timecode(text: "10:00:00:00:00", fps: 25) == nil)    // too many
        #expect(Timecode(text: "10-00-00-00", fps: 25) == nil)       // wrong separator
        #expect(Timecode(text: "aa:bb:cc:dd", fps: 25) == nil)
        #expect(Timecode(text: "10:00:xx:00", fps: 25) == nil)       // one junk field
    }

    /// A zero rate would make the frame-number arithmetic meaningless, so the
    /// parser floors it rather than storing it.
    @Test func parsedRateIsNeverZero() throws {
        let tc = try #require(Timecode(text: "00:00:01:00", fps: 0))
        #expect(tc.fps == 1)
        #expect(tc.frameNumber == 1)
    }

    // MARK: - non-drop-frame is left alone

    /// 30 fps without the drop flag numbers every frame: the DF correction must
    /// not leak into a 30 NDF signal (an ARRI at 30.000 is a real source).
    @Test func nonDropFrameAtThirtyKeepsEveryFrame() {
        let tc = Timecode(hours: 0, minutes: 1, seconds: 0, frames: 0, fps: 30)
        #expect(tc.frameNumber == 1800)
        #expect(Timecode(frameNumber: 1800, fps: 30) == tc)
        let boundary = Timecode(hours: 0, minutes: 0, seconds: 59, frames: 29, fps: 30)
        #expect(boundary.advanced(by: 1) == tc)
    }

    // MARK: - fps 0

    /// `init(frameNumber:fps:)` used to divide by `fps` unclamped while both
    /// sibling initializers clamped, and fps 0 is not hypothetical: the DeckLink
    /// adapter builds every frame's timecode with fps 0 on purpose and lets the
    /// pipeline fill the rate in from the format, whose `timecodeFPS` the bridge
    /// derives as `lround(frameRate)` — 0 for anything under 0.5 fps. That fed
    /// the pre-roll timecode shift, so the app trapped as a take opened.
    @Test func zeroFPSDoesNotTrap() {
        let tc = Timecode(frameNumber: 1234, fps: 0)
        #expect(tc.fps == 1)
        #expect(tc.frameNumber == 1234)
        // the path that crashed: advancing a timecode carried in with fps 0
        let carried = Timecode(hours: 9, minutes: 0, seconds: 0, frames: 0, fps: 0)
        #expect(carried.advanced(by: -20).fps == 1)
    }
}
