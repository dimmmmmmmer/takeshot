import CaptureCore
import CoreGraphics
import CoreVideo
import Foundation
import Testing

@testable import TakeShotKit

/// The vectorscope's graticule against the analyzer that fills it.
///
/// A vectorscope is only worth looking at if a known bar lands on its box, so
/// that is what is measured here rather than how the graticule looks: the
/// targets and the density map are both positioned by `ScopeAnalyzer.chroma`,
/// and the whole design rests on the two staying in step. They stopped being
/// trivially in step when the analyzer started reading the un-expanded wire —
/// a limited-range frame's chroma is 876/1023 of the same picture's full-range
/// chroma, and without the gain that corrects it every bar would sit inside its
/// box and read as a desaturated camera.
@MainActor
struct ModelVectorscopeTests {
    /// A flat BGRA frame.
    private func flat(r: Int, g: Int, b: Int) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                            &pb)
        let buffer = try #require(pb)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer))
            .assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<64 {
            for x in 0..<64 {
                let p = base + y * rowBytes + x * 4
                p[0] = UInt8(b); p[1] = UInt8(g); p[2] = UInt8(r); p[3] = 255
            }
        }
        return buffer
    }

    /// A flat r210 frame in LIMITED wire codes.
    private func flatWire(r: Int, g: Int, b: Int) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, TenBitConverter.r210,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                            &pb)
        let buffer = try #require(pb)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer))
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let word = ((UInt32(r) << 20) | (UInt32(g) << 10) | UInt32(b)).bigEndian
        for y in 0..<64 {
            let row = base.advanced(by: y * rowBytes)
                .assumingMemoryBound(to: UInt32.self)
            for x in 0..<64 { row[x] = word }
        }
        return buffer
    }

    /// A full-range 8-bit value as the limited 10-bit wire code that carries it.
    private func wireCode(_ eightBit: Int) -> Int {
        let full = (eightBit << 2) | (eightBit >> 6)
        return 64 + Int((Double(full) * 876 / 1023).rounded())
    }

    /// Where the density actually landed, in unit coordinates inside the square.
    private func peak(_ data: ScopeData) throws -> CGPoint {
        let size = ScopeData.vectorSize
        let index = try #require(data.vector.firstIndex(of: data.vector.max()!))
        return CGPoint(x: CGFloat(index % size) / CGFloat(size),
                       y: CGFloat(index / size) / CGFloat(size))
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
    }

    /// The graticule the operator lines a chart up on: six 75 % boxes and six
    /// 100 % marks, no more and no fewer.
    @Test func theGraticuleCarriesBothBarAmplitudes() {
        #expect(VectorscopeView.targets75.count == 6)
        #expect(VectorscopeView.targets100.count == 6)
        #expect(Set(VectorscopeView.targets75.map(\.id))
            == ["R", "G", "B", "Cy", "Mg", "Yl"])
        // 100 % of a hue is further from the centre than 75 % of it
        for (full, three) in zip(VectorscopeView.targets100,
                                 VectorscopeView.targets75) {
            let centre = CGPoint(x: 0.5, y: 0.5)
            #expect(distance(CGPoint(x: full.x, y: full.y), centre)
                > distance(CGPoint(x: three.x, y: three.y), centre))
        }
    }

    /// The radii the graticule is actually drawn at, in units of the half-width
    /// — which is also the radius of the outer circle.
    ///
    /// Worth pinning because the tempting simplification is wrong: the Cb/Cr
    /// plane is not isotropic, the six hues do NOT share a radius, and a
    /// graticule built on "100 % is the outer circle" would have to move green
    /// and magenta a fifth of the way in to make the sentence true. Both the
    /// file comments and the choice to mark the 100 % set individually rest on
    /// these numbers, so here they are as numbers.
    @Test func theTargetRadiiAreTheOnesTheChromaPlaneGives() throws {
        let atSeventyFive = ["B": 0.752, "Yl": 0.752, "R": 0.768,
                             "Cy": 0.768, "G": 0.892, "Mg": 0.892]
        let atFull = ["B": 1.004, "Yl": 1.004, "R": 1.026,
                      "Cy": 1.026, "G": 1.191, "Mg": 1.191]
        for (targets, expected) in [(VectorscopeView.targets75, atSeventyFive),
                                    (VectorscopeView.targets100, atFull)] {
            for target in targets {
                let want = try #require(expected[target.id])
                let radius = distance(CGPoint(x: target.x, y: target.y),
                                      CGPoint(x: 0.5, y: 0.5)) / 0.5
                #expect(abs(radius - want) < 0.002,
                        "\(target.id) at \(radius) of the half-width, not \(want)")
            }
        }
        // and every 100 % mark is still inside the square it is drawn in, so
        // the radial tick has somewhere to land instead of being clipped off
        for target in VectorscopeView.targets100 {
            #expect((0...1).contains(target.x) && (0...1).contains(target.y),
                    "\(target.id) at (\(target.x), \(target.y)) is off the scope")
        }
    }

    /// One colour bar of the standard set: the hue's name and its RGB.
    private struct Bar {
        let id: String
        let red: Int
        let green: Int
        let blue: Int
    }

    /// A 75 % colour bar lands on its own box. One box per hue, measured.
    @Test func seventyFivePercentBarsLandOnTheirBoxes() throws {
        let v = 191
        let bars = [Bar(id: "R", red: v, green: 0, blue: 0),
                    Bar(id: "G", red: 0, green: v, blue: 0),
                    Bar(id: "B", red: 0, green: 0, blue: v),
                    Bar(id: "Cy", red: 0, green: v, blue: v),
                    Bar(id: "Mg", red: v, green: 0, blue: v),
                    Bar(id: "Yl", red: v, green: v, blue: 0)]
        for bar in bars {
            let data = try #require(ScopeAnalyzer.analyze(
                try flat(r: bar.red, g: bar.green, b: bar.blue)))
            let target = try #require(
                VectorscopeView.targets75.first { $0.id == bar.id })
            let landed = try peak(data)
            let miss = distance(landed, CGPoint(x: target.x, y: target.y))
            // one cell of a 256-wide map is 1/256 = 0.004 of the square, and
            // the analyzer truncates rather than rounds into it — so up to one
            // cell on each axis, and nothing like a box width
            #expect(miss < 0.012,
                    "\(bar.id) landed at \(landed), box at (\(target.x), \(target.y))")
        }
    }

    /// The same bar read off the un-expanded 10-bit WIRE lands on the same box.
    ///
    /// Without the chroma gain it would sit at 876/1023 of the radius — inside
    /// the box, about 12 % short — which looks exactly like a camera that is
    /// slightly desaturated rather than like a scope with the wrong scale on it.
    @Test func aWireBarLandsOnTheSameBoxAsTheExpandedOne() throws {
        let target = try #require(VectorscopeView.targets75.first { $0.id == "R" })
        let data = try #require(ScopeAnalyzer.analyze(
            try flatWire(r: wireCode(191), g: wireCode(0), b: wireCode(0)),
            wireLevels: .limited))
        let landed = try peak(data)
        let miss = distance(landed, CGPoint(x: target.x, y: target.y))
        #expect(miss < 0.015,
                "wire 75 % red landed at \(landed), box at (\(target.x), \(target.y))")

        // …and with the gain left off it would visibly under-shoot, which is
        // what makes the assertion above worth making
        let unscaled = try #require(ScopeAnalyzer.analyze(
            try flatWire(r: wireCode(191), g: wireCode(0), b: wireCode(0)),
            wireLevels: .full))
        let short = try peak(unscaled)
        let centre = CGPoint(x: 0.5, y: 0.5)
        #expect(distance(short, centre)
            < distance(CGPoint(x: target.x, y: target.y), centre) - 0.02)
    }

    /// The skin-tone line is the I axis at 123° from +Cb, and re-expressing it
    /// as an angle did not move it: the direction it points is the one the
    /// hand-measured end point used to draw, to three decimals.
    ///
    /// A face sits on this line, so a couple of degrees of drift here reports a
    /// white balance as wrong when it is not — and nothing on screen would show
    /// it.
    @Test func theSkinToneLineIsTheIAxisAndHasNotMoved() {
        let angle = VectorscopeGraticule.skinToneAngle
        #expect(abs(angle - 123.0 * Double.pi / 180) < 1e-12)
        // the previous graticule drew to (-0.26, -0.40) in view coordinates,
        // i.e. up and to the left; normalized that is (-0.545, +0.839) in
        // chroma coordinates
        let length = (0.26 * 0.26 + 0.40 * 0.40).squareRoot()
        #expect(abs(cos(angle) - (-0.26 / length)) < 0.005)
        #expect(abs(sin(angle) - (0.40 / length)) < 0.005)
        #expect(cos(angle) < 0 && sin(angle) > 0,
                "the I axis runs up and to the left")
    }
}
