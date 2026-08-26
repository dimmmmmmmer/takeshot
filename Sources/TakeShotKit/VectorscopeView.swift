import CaptureCore
import CoreGraphics
import SwiftUI

/// Vectorscope: chroma density colored by its own hue, under a graticule built
/// from the same chroma math the analyzer plots with.
///
/// Scale: the density map covers full-range chroma ±511 across ±half the box.
/// The six hues do NOT sit at one radius on that map and no graticule should
/// pretend they do — the Cb/Cr plane is not isotropic, and measured in units of
/// the half-width the 75 % bars land at 0.752 (B, Yl), 0.768 (R, Cy) and 0.892
/// (G, Mg), with the 100 % set at 1.004, 1.026 and 1.191. Every mark here is
/// placed by `ScopeAnalyzer.chroma` for that reason rather than by a fraction
/// chosen to look right: a bar lands on its own box because both ends of the
/// scope compute the same number, and `ModelVectorscopeTests` measures it.
struct VectorscopeView: View {
    let data: ScopeData
    /// The ~33° skin-tone reference line. On for faces, off for anything the
    /// line would just cross (charts, bars, a graphic).
    var skinToneLine = true

    /// Hue for every (Cb, Cr) cell — computed once. Saturation follows the
    /// radius, so near-neutral chroma reads near-white instead of screaming.
    private static let hueLUT: [UInt8] = {
        let size = ScopeData.vectorSize
        var lut = [UInt8](repeating: 0, count: size * size * 3)
        for row in 0..<size {
            let cr = (Double(size) / 2 - Double(row)) * 255 / Double(size)
            for col in 0..<size {
                let cb = (Double(col) - Double(size) / 2) * 255 / Double(size)
                var r = 1.5748 * cr
                var g = -0.1873 * cb - 0.4681 * cr
                var b = 1.8556 * cb
                let peak = max(abs(r), abs(g), abs(b), 1)
                let saturation = min(1.0, (cb * cb + cr * cr).squareRoot() / 60)
                r = 255 * (1 - saturation) + (r / peak * 127 + 128) * saturation
                g = 255 * (1 - saturation) + (g / peak * 127 + 128) * saturation
                b = 255 * (1 - saturation) + (b / peak * 127 + 128) * saturation
                let i = (row * size + col) * 3
                lut[i] = UInt8(max(0, min(255, r)))
                lut[i + 1] = UInt8(max(0, min(255, g)))
                lut[i + 2] = UInt8(max(0, min(255, b)))
            }
        }
        return lut
    }()

    /// One colour-bar target on the vectorscope, in unit coordinates inside the
    /// scope square.
    struct VectorTarget: Identifiable {
        let id: String       // "R", "Cy", …
        let x: CGFloat
        let y: CGFloat
    }

    /// A target's unit position, from the exact same chroma math the analyzer
    /// plots with — which is why a bar lands on its box instead of near it.
    /// Including the PRIMARIES: a bar's chroma is a fact about the matrix that
    /// coded it, so both ends have to be told which one the signal is in.
    static func target(_ name: String, _ r: Int, _ g: Int, _ b: Int,
                       primaries: SignalPrimaries) -> VectorTarget {
        let (cb, cr) = ScopeAnalyzer.chroma(r: Double(r), g: Double(g),
                                            b: Double(b), primaries: primaries)
        return VectorTarget(id: name, x: CGFloat(0.5 + cb / 255),
                            y: CGFloat(0.5 - cr / 255))
    }

    /// The six colour-bar hues, at a given bar amplitude in 8-bit units.
    ///
    /// Where the boxes sit depends on the signal, and that is the whole point:
    /// Rec.2020 codes luma with different weights, so the same bar has
    /// different chroma, and a graticule fixed on 709 is the documented reason
    /// a Rec.2020 chart used to miss its boxes. It is not a tolerance question
    /// — 2020's red target sits about a tenth of the scope's width from 709's.
    static func targets(atAmplitude v: Int,
                        primaries: SignalPrimaries) -> [VectorTarget] {
        [target("R", v, 0, 0, primaries: primaries),
         target("G", 0, v, 0, primaries: primaries),
         target("B", 0, 0, v, primaries: primaries),
         target("Cy", 0, v, v, primaries: primaries),
         target("Mg", v, 0, v, primaries: primaries),
         target("Yl", v, v, 0, primaries: primaries)]
    }

    /// 75 % bars — the boxes an operator actually lines a chart up on.
    static func targets75(_ primaries: SignalPrimaries) -> [VectorTarget] {
        targets(atAmplitude: 191, primaries: primaries)
    }

    /// 100 % bars — marked, not boxed: they sit on the outer circle, and a full
    /// box there would be half outside the scope.
    static func targets100(_ primaries: SignalPrimaries) -> [VectorTarget] {
        targets(atAmplitude: 255, primaries: primaries)
    }

    /// How much of the box the scope square is allowed to take.
    ///
    /// It used to take all of it: measured in a 472x295 box the graticule ran
    /// from the first row of the canvas to the last, so the boundary circle was
    /// drawn hard against the frame, the rounded corners of the box clipped the
    /// square's own corners, and the G/Mg 100 % marks — which sit at 0.954 of
    /// the height — landed four points from the edge. That is what "the
    /// vectorscope does not fit inside its scope" looks like: nothing overflowed,
    /// there was simply no gap between the measurement and the box holding it.
    /// 3 % a side separates them at every size the panel offers and costs 6 % of
    /// the diameter.
    static let boxFill = 0.94

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height) * Self.boxFill
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            ZStack {
                if let image = ScopeImageCache.vector(from: data) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                        .frame(width: side, height: side)
                        .position(x: center.x, y: center.y)
                }
                VectorscopeGraticule(side: side, center: center,
                                     skinToneLine: skinToneLine,
                                     primaries: data.primaries)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Density map × hue LUT → RGBA image. Called once per analyzed frame by
    /// `ScopeImageCache` — a resize, a slider tick or a re-render of anything
    /// else in the panel reuses the image instead of walking 65 k cells again.
    static func coloredVector(_ data: ScopeData) -> CGImage? {
        let size = ScopeData.vectorSize
        var rgba = [UInt8](repeating: 0, count: size * size * 4)
        let lut = Self.hueLUT
        for i in 0..<(size * size) {
            let density = Int(data.vector[i])
            guard density > 0 else { continue }
            rgba[i * 4] = UInt8(Int(lut[i * 3]) * density / 255)
            rgba[i * 4 + 1] = UInt8(Int(lut[i * 3 + 1]) * density / 255)
            rgba[i * 4 + 2] = UInt8(Int(lut[i * 3 + 2]) * density / 255)
            rgba[i * 4 + 3] = 255
        }
        return rgbaImage(from: rgba, width: size, height: size)
    }
}
