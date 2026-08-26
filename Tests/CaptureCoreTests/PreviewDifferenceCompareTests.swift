import CoreImage
import CoreVideo
import Foundation
import Testing

@testable import CaptureCore

/// The difference compare, measured through the real display path.
///
/// Wipe and blend show the operator what they SEE — both halves carry the
/// preview LUT, which keeps the seam fair. Difference is the opposite
/// contract: it is a measurement of the signal (framing match, double
/// exposure, "did anything move"), so it must read the pre-LUT stage on both
/// halves and its output must bypass the viewing LUT. These pin that contract
/// with exact code values, because the wrong stage does not fail loudly — it
/// produces a plausible-looking picture whose numbers are quietly bent by
/// whatever look happens to be loaded.
@Suite struct PreviewDifferenceCompareTests {
    /// A 2³ .cube that maps everything to red — big enough to prove the LUT is
    /// in (or out of) the path, small enough to not test the parser.
    private static let redCube = """
        LUT_3D_SIZE 2
        \(Array(repeating: "1.0 0.0 0.0", count: 8).joined(separator: "\n"))
        """

    /// Largest B/G/R byte anywhere in the frame — "exact black" is a claim
    /// about every pixel, not about a sampled one. Alpha is excluded: the
    /// composite is opaque by construction.
    private func maxCode(of buffer: CVPixelBuffer) -> Int {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return -1 }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var worst = 0
        for y in 0..<height {
            let row = bytes + y * rowBytes
            for x in 0..<width {
                worst = max(worst, Int(row[x * 4]), Int(row[x * 4 + 1]),
                            Int(row[x * 4 + 2]))
            }
        }
        return worst
    }

    /// |A−B| of the pinned reference against the live signal reaches the
    /// screen at the dialled gain, and the compare provider keeps offering the
    /// clean frame — pinning a second reference while a difference is on
    /// screen must never pin the difference.
    @Test func differenceAgainstThePinnedReferenceReachesTheScreen() async throws {
        let pipeline = PreviewProbe.makePipeline()
        let collector = PreviewCollector()
        pipeline.setOnDisplayFrame { collector.record($0[.decorated]) }
        defer { pipeline.setOnDisplayFrame(nil) }

        pipeline.setPreviewReference(buffer: PreviewProbe.frame(0x40))
        pipeline.setPreviewCompare(.difference(gain: 4))

        let live = PreviewProbe.frame(0x4A) // 10 codes above the reference
        PreviewProbe.push(pipeline, live, frame: 1)
        await TestWait.until { collector.count > 0 }

        let presented = try #require(collector.last, "nothing was presented")
        for channel in 0..<3 {
            let value = PreviewProbe.level(of: presented, atFractionX: 0.5,
                                           channel: channel)
            #expect(value == 40, "channel \(channel): \(value), expected 10 × 4")
        }
        // …and the provider still hands out the clean frame
        let clean = try #require(pipeline.currentPreviewBuffer())
        #expect(PreviewProbe.level(of: clean) == 0x4A)
    }

    /// Identical frames come out EXACT black across the whole buffer — any
    /// bias would light up a frame that matches perfectly, and the gain would
    /// amplify the false positive rather than the truth.
    @Test func identicalFramesDifferenceToExactBlackThroughTheRealPath() async throws {
        let pipeline = PreviewProbe.makePipeline()
        let collector = PreviewCollector()
        pipeline.setOnDisplayFrame { collector.record($0[.decorated]) }
        defer { pipeline.setOnDisplayFrame(nil) }

        pipeline.setPreviewReference(buffer: PreviewProbe.frame(0x40))
        pipeline.setPreviewCompare(.difference(gain: 16))

        let live = PreviewProbe.frame(0x40)
        PreviewProbe.push(pipeline, live, frame: 1)
        await TestWait.until { collector.count > 0 }

        let presented = try #require(collector.last, "nothing was presented")
        #expect(presented !== live, "the difference was never composited")
        #expect(maxCode(of: presented) == 0,
                "identical frames left a residue of \(maxCode(of: presented))")
    }

    /// The measurement ignores the preview LUT. With a LUT that turns
    /// everything red, wipe/blend rightly show red on both halves — difference
    /// must still read |A−B| of the clean signal, exactly.
    @Test func differenceIsMeasuredBeforeThePreviewLUT() async throws {
        let pipeline = PreviewProbe.makePipeline()
        let collector = PreviewCollector()
        pipeline.setOnDisplayFrame { collector.record($0[.decorated]) }
        defer { pipeline.setOnDisplayFrame(nil) }
        pipeline.setLUT(try CubeLUT.parse(Self.redCube), preview: true,
                        record: false, intensity: 1)

        pipeline.setPreviewReference(buffer: PreviewProbe.frame(0x40))
        pipeline.setPreviewCompare(.difference(gain: 1))

        PreviewProbe.push(pipeline, PreviewProbe.frame(0x4A), frame: 1)
        await TestWait.until { collector.count > 0 }

        let presented = try #require(collector.last, "nothing was presented")
        // measured post-LUT this would be red-dominant (|red − gray|); the
        // pre-LUT measurement is 10 codes on every channel
        for channel in 0..<3 {
            let value = PreviewProbe.level(of: presented, atFractionX: 0.5,
                                           channel: channel)
            #expect(value == 10,
                    "channel \(channel): \(value) — the LUT bent the measurement")
        }
    }

    /// A reference pinned WHILE the LUT is active still measures the clean
    /// signal (the pin keeps a pre-LUT copy alongside the display one), and
    /// the wipe keeps comparing what the operator saw — the display copy, LUT
    /// and all. One pin, two stages, each mode reading its own.
    @Test func aPinTakenUnderTheLUTStillMeasuresTheCleanSignal() async throws {
        let pipeline = PreviewProbe.makePipeline()
        let collector = PreviewCollector()
        pipeline.setOnDisplayFrame { collector.record($0[.decorated]) }
        defer { pipeline.setOnDisplayFrame(nil) }
        pipeline.setLUT(try CubeLUT.parse(Self.redCube), preview: true,
                        record: false, intensity: 1)

        PreviewProbe.push(pipeline, PreviewProbe.frame(0x40), frame: 1)
        await TestWait.until { pipeline.currentPreviewBuffer() != nil }
        pipeline.pinReferenceFromCurrentFrame()
        pipeline.setPreviewCompare(.difference(gain: 16))
        pipeline.queue.sync {} // the pin is queue-async; let it land

        PreviewProbe.push(pipeline, PreviewProbe.frame(0x40), frame: 2)
        await TestWait.until { collector.count > 1 }

        let difference = try #require(collector.last)
        #expect(maxCode(of: difference) == 0,
                "the pin baked the LUT in — residue \(maxCode(of: difference))")

        // the wipe against the same pin shows the DISPLAY copy: red, because
        // red is what was on screen when the operator pinned it
        pipeline.setPreviewCompare(.wipe(axis: .vertical, position: 0.5))
        PreviewProbe.push(pipeline, PreviewProbe.frame(0x20), frame: 3)
        await TestWait.until {
            guard let last = collector.last else { return false }
            return PreviewProbe.level(of: last, atFractionX: 0.1, channel: 2) > 0xA0
        }
        let wiped = try #require(collector.last)
        let red = PreviewProbe.level(of: wiped, atFractionX: 0.1, channel: 2)
        let blue = PreviewProbe.level(of: wiped, atFractionX: 0.1, channel: 0)
        #expect(red > 0xA0 && blue < 0x40,
                "the wipe lost the WYSIWYG pin: R\(red) B\(blue)")
    }
}
