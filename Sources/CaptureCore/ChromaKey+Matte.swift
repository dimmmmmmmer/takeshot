import Foundation

/// The keyer's arithmetic: how far a pixel is from the screen color, how much
/// of it survives, how the screen's hue is pulled back out of what does, and
/// the color cube all of that is baked into for the GPU.
///
/// Split out of `ChromaKey` (which is the operator's settings) because this is
/// the part the tests measure pixel by pixel, and because it is the part that
/// has to stay understandable: every step below is stated in chroma distance,
/// which is the number the tolerance slider is in.
extension ChromaKey {
    /// BT.709 luma — the same weights the assist chain's grayscale uses, so a
    /// pixel means the same thing to the keyer and to the exposure tools.
    public static func luma(_ color: RGB) -> Double {
        0.2126 * color.red + 0.7152 * color.green + 0.0722 * color.blue
    }

    /// (Cb, Cr) of a display-RGB triple, BT.709, each roughly ±0.5.
    ///
    /// The key is measured in CHROMA and not in RGB distance on purpose: a cyc
    /// is lit unevenly and falls off into the corners, so the same green comes
    /// back two stops down at the edge of frame. Its chroma barely moves;
    /// its RGB distance moves by more than any usable tolerance.
    public static func chroma(_ color: RGB) -> (cb: Double, cr: Double) {
        let y = luma(color)
        return ((color.blue - y) / 1.8556, (color.red - y) / 1.5748)
    }

    /// Back to display RGB from luma and chroma, clamped into the cube.
    static func rgb(luma y: Double, cb: Double, cr: Double) -> RGB {
        RGB(y + 1.5748 * cr,
            y - 0.1873 * cb - 0.4681 * cr,
            y + 1.8556 * cb).clamped()
    }

    /// The per-pixel arithmetic with everything that does not depend on the
    /// pixel worked out in advance: where the key sits in the chroma plane,
    /// which way it points, and where the feather begins and ends.
    ///
    /// It exists for one reason — the cube walks 32 768 lattice points on every
    /// changed parameter, and re-deriving the key's own chroma inside that loop
    /// was most of what the rebuild cost. Everything below goes through it, so
    /// there is still exactly one copy of the math.
    struct Kernel: Sendable {
        let keyCb: Double
        let keyCr: Double
        /// Unit vector along the key's chroma; zero for an achromatic key,
        /// which has no direction to despill along.
        let unitCb: Double
        let unitCr: Double
        let tolerance: Double
        let featherEnd: Double
        let softness: Double
        let spill: Double

        init(_ key: ChromaKey) {
            let chroma = ChromaKey.chroma(key.keyColor)
            keyCb = chroma.cb
            keyCr = chroma.cr
            let magnitude = (chroma.cb * chroma.cb
                + chroma.cr * chroma.cr).squareRoot()
            unitCb = magnitude > 1e-6 ? chroma.cb / magnitude : 0
            unitCr = magnitude > 1e-6 ? chroma.cr / magnitude : 0
            tolerance = key.tolerance
            softness = key.softness
            featherEnd = key.tolerance + key.softness
            spill = key.spill
        }

        /// 0 where the pixel is screen, 1 where it is subject, smooth between.
        ///
        /// Smoothstep rather than a straight ramp — a linear feather leaves a
        /// visible corner at each end of the transition, which on hair reads as
        /// a second edge just outside the first.
        func matte(cb: Double, cr: Double) -> Double {
            let distance = ((cb - keyCb) * (cb - keyCb)
                + (cr - keyCr) * (cr - keyCr)).squareRoot()
            if distance <= tolerance { return 0 }
            guard softness > 0, distance < featherEnd else { return 1 }
            let t = (distance - tolerance) / softness
            return t * t * (3 - 2 * t)
        }

        /// The chroma with the key's hue pulled out of it. A color leaning AWAY
        /// from the screen (skin against green) comes back untouched, because
        /// its projection onto the key direction is negative.
        func despilled(cb: Double, cr: Double) -> (cb: Double, cr: Double) {
            guard spill > 0 else { return (cb, cr) }
            let along = cb * unitCb + cr * unitCr
            guard along > 0 else { return (cb, cr) }
            let cut = along * spill
            return (cb - unitCb * cut, cr - unitCr * cut)
        }
    }

    var kernel: Kernel { Kernel(self) }

    /// Chroma distance from the key color. 0 is the screen exactly; a subject
    /// against a green cyc measures 0.3 and up.
    public func distance(of color: RGB) -> Double {
        let key = Self.chroma(keyColor)
        let pixel = Self.chroma(color)
        return ((pixel.cb - key.cb) * (pixel.cb - key.cb)
            + (pixel.cr - key.cr) * (pixel.cr - key.cr)).squareRoot()
    }

    /// The matte: 0 where the pixel is screen (background shows through), 1
    /// where it is subject, smooth across the feather between them.
    public func matte(for color: RGB) -> Double {
        let pixel = Self.chroma(color)
        return kernel.matte(cb: pixel.cb, cr: pixel.cr)
    }

    /// Spill suppression: the screen bouncing off the cyc onto the subject's
    /// shoulders and hair, pulled back out.
    ///
    /// Luma is preserved, so the despilled edge stays where the exposure put it
    /// instead of going dark the way a plain "clip green to the red/blue
    /// average" despill leaves it.
    public func suppressed(_ color: RGB) -> RGB {
        guard spill > 0 else { return color }
        let pixel = Self.chroma(color)
        let cleaned = kernel.despilled(cb: pixel.cb, cr: pixel.cr)
        guard cleaned.cb != pixel.cb || cleaned.cr != pixel.cr else { return color }
        return Self.rgb(luma: Self.luma(color), cb: cleaned.cb, cr: cleaned.cr)
    }

    // MARK: - the color cube

    /// The parameters the lookup table actually depends on.
    ///
    /// The background does not: the table maps a pixel to a despilled color and
    /// an alpha, and what shows through the alpha is composited afterwards.
    /// Kept apart so that moving the background color well does not rebuild
    /// 512 KB of cube sixty times a second.
    struct CubeKey: Equatable {
        let color: RGB
        let tolerance: Double
        let softness: Double
        let spill: Double
        let matteOnly: Bool
    }

    var cubeKey: CubeKey {
        CubeKey(color: keyColor, tolerance: tolerance, softness: softness,
                spill: spill, matteOnly: background == .matte)
    }

    /// Lattice size of the cube the GPU keys through.
    ///
    /// 32 and not 64, which is what the exposure palettes use: those are built
    /// once for the process, this one is rebuilt every time a slider ticks.
    /// A 64³ cube is 4 MB and ~2 ms of arithmetic per rebuild — on the display
    /// queue, at slider rate, that is the effect dropping frames while the
    /// operator dials it in. 32³ is 512 KB and a fifth of the cost, and the
    /// trilinear interpolation between lattice points lands the matte edge
    /// within a couple of code values of where the math puts it — well inside
    /// the feather the softness control adds anyway.
    public static let cubeDimension = 32

    /// The whole key as one lookup table: RGB in, premultiplied RGBA out, with
    /// alpha carrying the matte.
    ///
    /// `matteOnly` swaps in the black-and-white view — the matte itself as an
    /// opaque picture, which is what tells the operator whether the key is
    /// clean before anything is composited behind it.
    ///
    /// CIColorCube wants premultiplied entries, so the color is scaled by its
    /// own alpha here rather than anywhere later.
    /// Written into a buffer sized up front and indexed, rather than appended
    /// to: four appends per lattice point is 131 072 of them, and the array
    /// literal the obvious version reaches for allocates once per pixel.
    public func cubeData(dimension size: Int = ChromaKey.cubeDimension,
                         matteOnly: Bool) -> Data {
        let kernel = self.kernel
        var rgba = [Float](repeating: 0, count: size * size * size * 4)
        let step = 1.0 / Double(size - 1)
        var index = 0
        for b in 0..<size {
            let blue = Double(b) * step
            for g in 0..<size {
                let green = Double(g) * step
                for r in 0..<size {
                    let red = Double(r) * step
                    let y = 0.2126 * red + 0.7152 * green + 0.0722 * blue
                    let cb = (blue - y) / 1.8556
                    let cr = (red - y) / 1.5748
                    let alpha = kernel.matte(cb: cb, cr: cr)
                    if matteOnly {
                        let v = Float(alpha)
                        rgba[index] = v
                        rgba[index + 1] = v
                        rgba[index + 2] = v
                        rgba[index + 3] = 1
                    } else {
                        let clean = kernel.despilled(cb: cb, cr: cr)
                        let out = Self.rgb(luma: y, cb: clean.cb, cr: clean.cr)
                        // premultiplied, which is what CIColorCube wants
                        rgba[index] = Float(out.red * alpha)
                        rgba[index + 1] = Float(out.green * alpha)
                        rgba[index + 2] = Float(out.blue * alpha)
                        rgba[index + 3] = Float(alpha)
                    }
                    index += 4
                }
            }
        }
        return rgba.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
