import Foundation

@testable import CaptureCore

/// The measuring instrument the cube tests use: a lattice sampled the way a GPU
/// samples it, so a generated cube can be held against the function it came
/// from.
///
/// It lives beside the suite rather than inside it because it is an instrument,
/// not an assertion — a reader checking what the 65³ decision rests on needs to
/// read this trilinear filter and satisfy themselves it is the same one
/// `CIColorCube` applies, and that is a different question from what any single
/// test claims.
enum CubeSampling {
    static func floats(_ cube: CubeLUT) -> [Float] {
        cube.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// Largest per-channel difference between the cube (sampled trilinearly)
    /// and the look evaluated directly, over every cell centre of the lattice.
    ///
    /// Cell centres and not lattice points: at a lattice point the cube is the
    /// function by construction and the error is zero, which measures nothing.
    /// The centre is where interpolation sits furthest from the curve.
    static func maxError(of look: CDLLook, size: Int) -> Double {
        let cube = look.cube(size: size)
        let values = floats(cube)
        let step = 1.0 / Double(size - 1)
        var worst = 0.0
        for blue in 0..<(size - 1) {
            for green in 0..<(size - 1) {
                for red in 0..<(size - 1) {
                    let point = CDLLook.RGB((Double(red) + 0.5) * step,
                                            (Double(green) + 0.5) * step,
                                            (Double(blue) + 0.5) * step)
                    let sampled = trilinear(values, size: size, at: point)
                    let exact = look.apply(point)
                    worst = max(worst, abs(sampled.r - exact.r))
                    worst = max(worst, abs(sampled.g - exact.g))
                    worst = max(worst, abs(sampled.b - exact.b))
                }
            }
        }
        return worst
    }

    /// One axis of the lookup: the two lattice planes it falls between and how
    /// far along it sits.
    struct Axis {
        let low: Int
        let high: Int
        let mix: Double

        init(_ value: Double, size: Int) {
            let scaled = min(1, max(0, value)) * Double(size - 1)
            low = min(size - 2, max(0, Int(scaled)))
            high = min(size - 1, low + 1)
            mix = scaled - Double(low)
        }

        /// The plane and its weight on one side of the cell.
        func side(_ upper: Bool) -> (plane: Int, weight: Double) {
            upper ? (high, mix) : (low, 1 - mix)
        }
    }

    /// Trilinear lookup into an RGBA float cube laid out red-fastest.
    static func trilinear(_ values: [Float], size: Int,
                          at point: CDLLook.RGB) -> CDLLook.RGB {
        let axes = [point.r, point.g, point.b].map { Axis($0, size: size) }
        var out = CDLLook.RGB(0, 0, 0)
        for corner in 0..<8 {
            let x = axes[0].side(corner & 1 == 1)
            let y = axes[1].side((corner >> 1) & 1 == 1)
            let z = axes[2].side((corner >> 2) & 1 == 1)
            let weight = x.weight * y.weight * z.weight
            guard weight != 0 else { continue }
            let base = ((z.plane * size + y.plane) * size + x.plane) * 4
            out.r += weight * Double(values[base])
            out.g += weight * Double(values[base + 1])
            out.b += weight * Double(values[base + 2])
        }
        return out
    }
}
