import CaptureCore
import CoreGraphics
import SwiftUI

/// Vectorscope: chroma density colored by its own hue, rings at 25/50/75%,
/// 75% primary/secondary targets and — when the operator wants it — the
/// skin-tone line.
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

    /// One 75% color-bar target box on the vectorscope.
    struct VectorTarget: Identifiable {
        let id: String       // "R", "Cy", …
        let x: CGFloat       // unit position inside the scope square
        let y: CGFloat
    }

    /// 75% color-bar targets — positioned by the exact same chroma math the
    /// analyzer plots with, so bars land on their boxes.
    private static let targets: [VectorTarget] = {
        func target(_ name: String, _ r: Int, _ g: Int, _ b: Int) -> VectorTarget {
            let (cb, cr) = ScopeAnalyzer.chroma(r: Double(r), g: Double(g),
                                                b: Double(b))
            return VectorTarget(id: name,
                                x: CGFloat(0.5 + cb / 255),
                                y: CGFloat(0.5 - cr / 255))
        }
        let v = 191 // 75%
        return [target("R", v, 0, 0), target("G", 0, v, 0), target("B", 0, 0, v),
                target("Cy", 0, v, v), target("Mg", v, 0, v),
                target("Yl", v, v, 0)]
    }()

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let cx = geo.size.width / 2, cy = geo.size.height / 2
            ZStack {
                if let image = ScopeImageCache.vector(from: data) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                        .frame(width: side, height: side)
                        .position(x: cx, y: cy)
                }
                // rings + cross + skin-tone line
                ForEach([0.25, 0.5, 0.75], id: \.self) { ring in
                    Circle()
                        .strokeBorder(.white.opacity(ring == 0.75 ? 0.3 : 0.15),
                                      lineWidth: 0.5)
                        .frame(width: side * ring, height: side * ring)
                        .position(x: cx, y: cy)
                }
                Path { p in
                    p.move(to: CGPoint(x: cx - side / 2, y: cy))
                    p.addLine(to: CGPoint(x: cx + side / 2, y: cy))
                    p.move(to: CGPoint(x: cx, y: cy - side / 2))
                    p.addLine(to: CGPoint(x: cx, y: cy + side / 2))
                    if skinToneLine {
                        // skin-tone line (~33° up-left of the +Cr axis)
                        p.move(to: CGPoint(x: cx, y: cy))
                        p.addLine(to: CGPoint(x: cx - side * 0.26,
                                              y: cy - side * 0.40))
                    }
                }
                .stroke(.white.opacity(0.22), lineWidth: 0.5)
                ForEach(Self.targets) { target in
                    let px = cx - side / 2 + target.x * side
                    let py = cy - side / 2 + target.y * side
                    Rectangle()
                        .strokeBorder(.white.opacity(0.5), lineWidth: 0.7)
                        .frame(width: 7, height: 7)
                        .position(x: px, y: py)
                    Text(target.id)
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .position(x: px + 9, y: py - 7)
                }
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
