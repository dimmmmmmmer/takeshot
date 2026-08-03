import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import CaptureCore

/// Levels and the preview LUT, measured on the frame that reaches the screen.
///
/// Both of these are stated once and applied once, and both have a specific
/// wrong answer that looks plausible: expanding a source that already carries
/// full range crushes the blacks, and a colour-managed LUT render makes the
/// same look land differently in live and in playback. The values below are the
/// ones the pipeline's comments commit to, checked end to end rather than on the
/// helper functions in isolation.
@Suite struct PreviewLevelsTests {
    /// A 2³ .cube that maps everything to red. Small on purpose: what is under
    /// test is that the LUT reaches the preview, not the parser.
    private static let redCube = """
        LUT_3D_SIZE 2
        \(Array(repeating: "1.0 0.0 0.0", count: 8).joined(separator: "\n"))
        """

    /// "limited" states what the SOURCE carries on the wire, and the expansion
    /// runs ONCE, on the gamma-encoded codes. Running it twice crushes the
    /// shadows; not running it is the washed-out preview the setting exists for.
    ///
    /// The window is the NOMINAL pair 16–235: black has to be black on the
    /// monitor, and on this 8-bit path the display buffer is also what the
    /// writer gets, so there is nowhere to keep the excursions anyway. The
    /// 10-bit path keeps them — in the file, which the operator is not
    /// judging exposure on.
    @Test func aLimitedRangeSourceIsExpandedOnTheDisplayFrame() async throws {
        let pipeline = PreviewProbe.makePipeline()
        let collector = PreviewCollector()
        pipeline.setOnDisplayFrame { collector.record($0) }
        defer { pipeline.setOnDisplayFrame(nil) }
        pipeline.setVideoLevels("limited")

        // nominal black and white land on the ends of the scale, in place, on
        // the frame that reaches the screen
        let black = PreviewProbe.frame(16)
        PreviewProbe.push(pipeline, black, frame: 1)
        await TestWait.until { collector.last === black }
        #expect(PreviewProbe.level(of: try #require(collector.last)) == 0,
                "16 did not expand to 0")

        let white = PreviewProbe.frame(235)
        PreviewProbe.push(pipeline, white, frame: 2)
        await TestWait.until { collector.last === white }
        #expect(PreviewProbe.level(of: try #require(collector.last)) == 255,
                "235 did not expand to 255")

        // …and a sub-black is black, not a dark grey the operator has to
        // second-guess
        let subBlack = PreviewProbe.frame(8)
        PreviewProbe.push(pipeline, subBlack, frame: 3)
        await TestWait.until { collector.last === subBlack }
        let below = PreviewProbe.level(of: try #require(collector.last))
        #expect(below == 0, "the sub-black was not clipped onto black: \(below)")

        // …and a source that already carries full range is passed through
        pipeline.setVideoLevels("full")
        let top = PreviewProbe.frame(254)
        PreviewProbe.push(pipeline, top, frame: 4)
        await TestWait.until { collector.last === top }
        #expect(PreviewProbe.level(of: try #require(collector.last)) == 254,
                "a full-range source was expanded anyway")
    }

    /// Levels on auto assume limited for RGB 4:4:4 — that is the CTA-861
    /// default, and it is what an HDMI camera actually sends.
    @Test func autoLevelsAssumeLimitedForRGB444() async throws {
        let pipeline = PreviewProbe.makePipeline(isRGB444: true)
        let collector = PreviewCollector()
        pipeline.setOnDisplayFrame { collector.record($0) }
        defer { pipeline.setOnDisplayFrame(nil) }

        // nominal white rather than a mid-grey: unexpanded it stays 235, so the
        // assertion fails when auto quietly stops expanding
        let white = PreviewProbe.frame(235)
        PreviewProbe.push(pipeline, white, frame: 1)
        await TestWait.until { collector.last === white }
        #expect(PreviewProbe.level(of: try #require(collector.last)) == 255,
                "an RGB 4:4:4 source was left unexpanded on auto")
    }

    /// The preview LUT is applied to what the operator sees, on raw code values
    /// — a colour-managed render here made live and playback diverge with the
    /// same look loaded. Intensity 0 is the clean-signal stop and has to give
    /// the original values back.
    @Test func thePreviewLUTIsAppliedToTheDisplayFrame() async throws {
        let pipeline = PreviewProbe.makePipeline()
        let collector = PreviewCollector()
        pipeline.setOnDisplayFrame { collector.record($0) }
        defer { pipeline.setOnDisplayFrame(nil) }
        pipeline.setLUT(try CubeLUT.parse(Self.redCube), preview: true,
                        record: false, intensity: 1)

        let source = PreviewProbe.frame(0x80)
        PreviewProbe.push(pipeline, source, frame: 1)
        await TestWait.until { collector.last != nil && collector.last !== source }

        let graded = try #require(collector.last)
        #expect(graded !== source, "the LUT never reached the preview")
        let red = PreviewProbe.level(of: graded, channel: 2)
        let blue = PreviewProbe.level(of: graded, channel: 0)
        #expect(red > blue + 60, "the look is not in the frame: R\(red) B\(blue)")

        // the clean-signal stop: still a rendered copy, but with the original
        // values — the operator checks the ungraded signal with it
        pipeline.setLUTIntensity(0)
        let second = PreviewProbe.frame(0x80)
        PreviewProbe.push(pipeline, second, frame: 2)
        await TestWait.until {
            collector.last != nil && collector.last !== graded
                && collector.last !== second
        }
        let clean = PreviewProbe.level(of: try #require(collector.last))
        #expect(abs(clean - 0x80) <= 3, "intensity 0 changed the image: \(clean)")
    }
}
