import AVFoundation
import Testing

@testable import CaptureCore

/// **Standard definition is not square-pixel, and a file with no `pasp` claims
/// it is.**
///
/// 720 samples across an active line is BT.601's number and it is not 720/576
/// in shape. Without the atom, a player draws PAL SD at 1.25:1 and NTSC SD at
/// 1.48:1 — everybody slightly too tall or too wide, on a raster that matches
/// no preset in any NLE, which is the kind of wrongness an assistant fixes by
/// eye and gets subtly different each time.
///
/// Asserted on the settings dictionary rather than on the finished file, for
/// the reason `HDRRecordTests` states: whether a given encoder writes the atom
/// is the host's behaviour, and whether the app ASKS for it is the app's.
struct WriterPixelAspectTests {
    private static func settings(width: Int, height: Int) -> [String: Any] {
        TakeWriter.videoSettings(
            format: CaptureFormat(width: width, height: height, frameRate: 25,
                                  timecodeFPS: 25, name: "test"),
            codec: .proResHQ, colorTagPreset: nil)
    }

    private static func aspect(width: Int, height: Int) -> [String: Any]? {
        settings(width: width, height: height)[AVVideoPixelAspectRatioKey]
            as? [String: Any]
    }

    @Test func theTwoStandardDefinitionRastersCarryTheirSamplingAspect()
        throws {
        for (width, height, horizontal, vertical) in [
            (720, 576, 59, 54),   // 625-line
            (720, 486, 10, 11),   // 525-line
            (720, 480, 10, 11),   // …and the 480 a converter may hand over
        ] {
            let atom = try #require(Self.aspect(width: width, height: height),
                                    "\(width)x\(height) claimed square pixels")
            #expect(atom[AVVideoPixelAspectRatioHorizontalSpacingKey]
                as? Int == horizontal)
            #expect(atom[AVVideoPixelAspectRatioVerticalSpacingKey]
                as? Int == vertical)
        }
    }

    /// **HD and above are square-pixel and must stay untouched.**
    ///
    /// The comparison that makes the assertion above mean something: a
    /// `pasp` on a 1080p file is not a harmless extra, it is a claim that the
    /// picture should be stretched.
    @Test func everyOtherRasterAsksForNothing() {
        for (width, height) in [(1920, 1080), (3840, 2160), (1280, 720),
                                (4096, 2160), (720, 1280)] {
            #expect(Self.aspect(width: width, height: height) == nil,
                    "\(width)x\(height) was tagged non-square")
        }
    }

    /// The choice, stated where it can be read back: 4:3 rather than 16:9.
    ///
    /// The signal does not say which it is — the app does not read WSS or AFD
    /// out of SD VANC — and a 16:9 SD source is ANAMORPHIC, which every NLE
    /// reinterprets in one click. Neither reading is available to a file that
    /// claims square pixels, which is what makes the 4:3 default the better of
    /// the two wrong answers and the untagged file the worst of the three.
    @Test func theSDAspectIsTheFourByThreeSamplingAspect() throws {
        // **Over the ACTIVE width, which is why these ratios look arbitrary.**
        // BT.601 samples 720 per line but only 702 of them (625-line) and 711
        // (525-line) carry picture; the sampling aspect is defined so that the
        // active part fills a 4:3 display. Worked out over all 720 the numbers
        // come out at 1.37 and 1.36 and look wrong, which is how a plausible
        // "correction" to 12:11 gets made by somebody checking the arithmetic
        // against the wrong width.
        for (height, active, aspect) in [
            (576, 702.0, try #require(TakeWriter.pixelAspect(width: 720,
                                                             height: 576))),
            (486, 711.0, try #require(TakeWriter.pixelAspect(width: 720,
                                                             height: 486))),
        ] {
            let displayed = active * Double(aspect.horizontal)
                / Double(aspect.vertical) / Double(height)
            #expect(abs(displayed - 4.0 / 3.0) < 0.01,
                    "\(height)-line SD displays at \(displayed):1")
        }
        // …and what the untagged file claimed, for the size of the error:
        // 1.25:1 against 1.33:1 is six per cent of everybody's width.
        #expect(abs(720.0 / 576.0 - 4.0 / 3.0) > 0.08)
    }
}
