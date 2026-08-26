import CaptureCore
import CoreGraphics
import CoreVideo
import Foundation
import SwiftUI
import Testing

@testable import TakeShotKit

/// The chromaticity chart's graticule against the analyzer that fills it.
///
/// The vectorscope's tests exist because "a 75 % bar lands on its box" is the
/// only thing that makes a vectorscope worth looking at. The same argument is
/// stronger here: on a chromaticity diagram nobody can tell by eye that a
/// colour is a percent off, so the ONE thing that can be checked is that the
/// two ends of the scope compute the same number — the analyzer deposits
/// through `ScopeData.cieUnit` and the graticule draws every mark through it
/// too.
@MainActor
struct ModelCIEChartTests {
    private static let side: CGFloat = 240
    private static let center = CGPoint(x: 120, y: 120)

    private func graticule(_ primaries: SignalPrimaries,
                           showsOtherGamut: Bool = true) -> CIEGraticule {
        CIEGraticule(side: Self.side, center: Self.center,
                     primaries: primaries, showsOtherGamut: showsOtherGamut)
    }

    /// A flat r210 frame in wire codes.
    private func flatWire(r: Int, g: Int, b: Int) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, TenBitConverter.r210,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                            &pb)
        let buffer = try #require(pb, "no r210 buffer was allocated")
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer),
                                "the r210 buffer has no base address")
        let rowBytes: Int = CVPixelBufferGetBytesPerRow(buffer)
        let word: UInt32 = ((UInt32(r) << 20) | (UInt32(g) << 10)
            | UInt32(b)).bigEndian
        for y: Int in 0..<64 {
            let row = base.advanced(by: y * rowBytes)
                .assumingMemoryBound(to: UInt32.self)
            for x: Int in 0..<64 { row[x] = word }
        }
        return buffer
    }

    /// Where the density landed, in the graticule's own canvas coordinates.
    private func plotted(_ data: ScopeData) throws -> CGPoint {
        let size: Int = ScopeData.cieSize
        let peak: UInt8 = try #require(data.cie.max(), "the chart map is empty")
        let index: Int = try #require(data.cie.firstIndex(of: peak),
                                      "the chart map has no peak")
        let unitX: CGFloat = (CGFloat(index % size) + 0.5) / CGFloat(size)
        let unitY: CGFloat = (CGFloat(index / size) + 0.5) / CGFloat(size)
        return CGPoint(x: Self.center.x - Self.side / 2 + unitX * Self.side,
                       y: Self.center.y - Self.side / 2 + unitY * Self.side)
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
    }

    /// A full-amplitude primary lands on the corner the graticule draws for it
    /// — in BOTH gamuts, through each gamut's own matrix. This is the chart's
    /// version of "the bar is in its box".
    ///
    /// One cell of a 256-cell map is `side / 256`, i.e. under a point at the
    /// size used here, so the tolerance is a couple of cells and nothing like
    /// the distance between the two gamuts' corners.
    @Test func aFullAmplitudePrimaryLandsOnItsOwnCorner() throws {
        for primaries: SignalPrimaries in [.rec709, .rec2020] {
            let data: ScopeData = try #require(ScopeAnalyzer.analyze(
                try flatWire(r: 940, g: 64, b: 64), wireLevels: .limited,
                colorimetry: WireColorimetry(transfer: .sdr,
                                             primaries: primaries)),
                                               "the analyzer refused the frame")
            let corner: CGPoint = graticule(primaries)
                .point(primaries.colorPrimaries.red)
            let landed: CGPoint = try plotted(data)
            #expect(distance(landed, corner) < 3,
                    "\(primaries) full red landed at \(landed), the graticule draws the corner at \(corner)")
        }
    }

    /// And the two gamuts' corners are far apart on the canvas, so the test
    /// above is measuring agreement rather than a tolerance wide enough to
    /// swallow the difference.
    @Test func theTwoGamutsCornersAreNowhereNearEachOther() {
        let sevenNine: CGPoint = graticule(.rec709).point(ColorPrimaries.rec709.red)
        let twenty: CGPoint = graticule(.rec709).point(ColorPrimaries.rec2020.red)
        #expect(distance(sevenNine, twenty) > 15,
                "the two red corners are \(distance(sevenNine, twenty)) points apart")
    }

    /// D65 sits where a neutral frame plots, which is what makes the cross an
    /// operator can judge white balance against.
    @Test func theWhitePointCrossSitsWhereNeutralPlots() throws {
        let data: ScopeData = try #require(ScopeAnalyzer.analyze(
            try flatWire(r: 500, g: 500, b: 500), wireLevels: .limited),
                                           "the analyzer refused the frame")
        let cross: CGPoint = graticule(.rec709).point(ColorPrimaries.d65)
        let landed: CGPoint = try plotted(data)
        #expect(distance(landed, cross) < 3,
                "neutral landed at \(landed), the cross is at \(cross)")
    }

    /// "The other gamut" is one function, and the chip in the box header and
    /// the quiet triangle in the graticule both go through it. Two spellings of
    /// it is how a chip ends up labelled 709 over a 2020 triangle.
    @Test func theSecondGamutIsAlwaysTheOneTheSignalIsNotIn() {
        #expect(CIEGraticule.other(than: .rec709) == .rec2020)
        #expect(CIEGraticule.other(than: .rec2020) == .rec709)
        #expect(CIEGraticule.name(of: .rec709) == "709")
        #expect(CIEGraticule.name(of: .rec2020) == "2020")
        #expect(graticule(.rec2020).otherPrimaries == .rec709)
    }

    /// The whole graticule stays inside the square it was given: the locus runs
    /// to the edge of the map, and a horseshoe drawn past the frame is the same
    /// fault the vectorscope had before `boxFill` existed.
    @Test func theGraticuleStaysInsideItsBox() {
        for point: Chromaticity in CIE1931.spectralLocus {
            let at: CGPoint = graticule(.rec709).point(point)
            #expect(at.x >= Self.center.x - Self.side / 2 - 0.001,
                    "a locus point left the square at x \(at.x)")
            #expect(at.x <= Self.center.x + Self.side / 2 + 0.001,
                    "a locus point left the square at x \(at.x)")
            #expect(at.y >= Self.center.y - Self.side / 2 - 0.001,
                    "a locus point left the square at y \(at.y)")
            #expect(at.y <= Self.center.y + Self.side / 2 + 0.001,
                    "a locus point left the square at y \(at.y)")
        }
    }

    /// The graticule obeys the panel's brightness slider, like the other four
    /// scopes' do — the histogram's and the vectorscope's both had to be fixed
    /// for ignoring it, so a fifth scope arriving deaf to it is the expected
    /// mistake rather than an unlikely one.
    @Test func theGraticuleFollowsTheBrightnessControl() async throws {
        try await ViewProbe.run { probe in
            let size = CGSize(width: 240, height: 240)
            @MainActor func brightness(_ level: Double) -> Double {
                ViewRender.meanBrightness(probe.hosted(
                    graticule(.rec709)
                        .environment(\.scopeGridBrightness, level)
                        .background(Color.black)), in: size)
            }
            let dim: Double = brightness(0.15)
            let bright: Double = brightness(1.0)
            #expect(bright > dim,
                    "the chromaticity graticule ignored the slider: \(dim) vs \(bright)")
        }
    }

    /// The second triangle is ink, not layout: switching it off draws less and
    /// moves nothing.
    @Test func theSecondGamutAddsInkAndNotGeometry() async throws {
        let data: ScopeData = try #require(ScopeAnalyzer.analyze(
            try flatWire(r: 500, g: 500, b: 500), wireLevels: .limited),
                                           "the analyzer refused the frame")
        try await ViewProbe.run { probe in
            let size = CGSize(width: 240, height: 240)
            let both: Double = ViewRender.meanBrightness(probe.hosted(
                graticule(.rec709)
                    .environment(\.scopeGridBrightness, 1.0)
                    .background(Color.black)), in: size)
            let one: Double = ViewRender.meanBrightness(probe.hosted(
                graticule(.rec709, showsOtherGamut: false)
                    .environment(\.scopeGridBrightness, 1.0)
                    .background(Color.black)), in: size)
            #expect(both > one,
                    "the second gamut drew nothing: \(one) vs \(both)")

            let on: CGSize = probe.size(
                CIEChartView(data: data, showsOtherGamut: true),
                proposedWidth: 300, proposedHeight: 300)
            let off: CGSize = probe.size(
                CIEChartView(data: data, showsOtherGamut: false),
                proposedWidth: 300, proposedHeight: 300)
            #expect(on == off, "the chart geometry changed: \(on) vs \(off)")
        }
    }

    /// The density map reaches the screen as an image of the map's own size,
    /// through the same per-frame cache every other scope's trace uses.
    @Test func theChartImageIsBuiltAtTheMapsResolution() throws {
        let data: ScopeData = try #require(ScopeAnalyzer.analyze(
            try flatWire(r: 940, g: 502, b: 64), wireLevels: .limited),
                                           "the analyzer refused the frame")
        let image: CGImage = try #require(
            ScopeImageCache.image(.cie, from: data),
            "the chromaticity chart produced no image")
        #expect(image.width == ScopeData.cieSize)
        #expect(image.height == ScopeData.cieSize)
    }

    /// Five scopes now, which is what the window's grid rule was already
    /// written for.
    @Test func theChartJoinsTheOtherFourScopes() {
        #expect(ScopeKind.allCases.count == 5)
        #expect(ScopeKind.allCases.contains(.cie))
        #expect(ScopeKind.cie.titleKey == "scope_cie")
        // a filled shape, like the histogram and the vectorscope: the trace
        // slider may not dim it into nothing
        #expect(ScopeKind.cie.minimumTraceOpacity > 0)
    }
}
