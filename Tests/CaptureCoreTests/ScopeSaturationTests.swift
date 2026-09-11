import CoreVideo
import Foundation
import Testing

@testable import CaptureCore

/// **The waveform's opacity follows the saturation of the shot** (owner: "чтоб
/// вейвформа по прозрачности реагировала на насыщенность в шоте — то что
/// насыщеннее видно явнее").
///
/// Two halves, measured separately and then together: the curve, and what a
/// real analyzed frame comes out at through it.
@Suite struct ScopeSaturationTests {
    /// The curve, as numbers rather than as a sentence — a floor for neutral,
    /// solid for fully saturated, and a straight line between them so the
    /// middle of the range is where the comparing happens.
    @Test func theOpacityCurveIsTheTableItClaims() {
        #expect(ScopeSaturation.opacity(forSaturation: 0) == 0.55)
        #expect(abs(ScopeSaturation.opacity(forSaturation: 0.25) - 0.6625) < 1e-9)
        #expect(abs(ScopeSaturation.opacity(forSaturation: 0.5) - 0.775) < 1e-9)
        #expect(ScopeSaturation.opacity(forSaturation: 1) == 1)
        // out-of-range values are clamped rather than trusted: a mean colour
        // is an average of clamped codes, but nothing in this file should
        // depend on that being true somewhere else.
        #expect(ScopeSaturation.opacity(forSaturation: 5) == 1)
        #expect(ScopeSaturation.opacity(forSaturation: -5) == 0.55)
    }

    /// Saturation itself: neutral is zero at every level, a primary is one,
    /// and black has no hue rather than an undefined one.
    @Test func saturationReadsTheColourAndNotTheLevel() {
        #expect(ScopeSaturation.of(r: 500, g: 500, b: 500) == 0)
        #expect(ScopeSaturation.of(r: 64, g: 64, b: 64) == 0)
        #expect(ScopeSaturation.of(r: 0, g: 0, b: 0) == 0)
        #expect(ScopeSaturation.of(r: 940, g: 64, b: 64) > 0.9)
        #expect(abs(ScopeSaturation.of(r: 800, g: 400, b: 400) - 0.5) < 1e-9)
    }

    /// **End to end, through the analyzer**: a saturated field draws a more
    /// opaque trace than a neutral one at the same luma.
    ///
    /// The two frames are chosen to land at the same place on the waveform —
    /// same luma, so the same rows, so the comparison is about the colour and
    /// nothing else.
    @Test func aSaturatedFrameDrawsAMoreOpaqueTraceThanANeutralOne() throws {
        let saturated = try #require(Self.trace(r: 200, g: 40, b: 40))
        let neutral = try #require(Self.trace(r: 96, g: 96, b: 96))
        #expect(saturated > neutral + 20, """
            a saturated field drew its trace at alpha \(saturated) and a \
            neutral one at \(neutral) — the emphasis is not reaching the map
            """)
        #expect(neutral > 100, """
            a neutral field's trace came back at alpha \(neutral) — the floor \
            exists so an exposure read survives this feature
            """)
    }

    /// The peak alpha of the coloured luma map for a flat field of one colour.
    private static func trace(r: UInt8, g: UInt8, b: UInt8) -> Int? {
        let buffer = TestMedia.pixelBuffer(width: 64, height: 32)
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            for row in 0..<32 {
                let line = bytes + row * rowBytes
                for column in 0..<64 {
                    line[column * 4] = b
                    line[column * 4 + 1] = g
                    line[column * 4 + 2] = r
                    line[column * 4 + 3] = 255
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard let data = ScopeAnalyzer.analyze(buffer) else { return nil }
        return stride(from: 3, to: data.waveformYColor.count, by: 4)
            .map { Int(data.waveformYColor[$0]) }
            .max()
    }
}
