import Foundation

/// The matrix that takes LINEAR R, G, B to CIE XYZ for one set of primaries.
///
/// Nine numbers, held as scalars rather than as an array because this runs once
/// per sample of the scope grid — `gridCols * gridRows` times a frame — and a
/// bounds-checked `[[Double]]` in that loop is the difference between a scope
/// pass that fits its stride interval and one that does not.
public struct RGBToXYZ: Sendable, Equatable {
    public let xr: Double, xg: Double, xb: Double
    public let yr: Double, yg: Double, yb: Double
    public let zr: Double, zg: Double, zb: Double

    /// Chromaticity of a linear RGB triple.
    ///
    /// nil for black, and that is the honest answer rather than a guard against
    /// a division: a pixel with no light in it has no hue, and plotting it
    /// somewhere would put a point on the chart that the picture does not have.
    /// Every camera frame has thousands of them.
    @inline(__always)
    public func chromaticity(r: Double, g: Double, b: Double) -> Chromaticity? {
        let x = xr * r + xg * g + xb * b
        let y = yr * r + yg * g + yb * b
        let z = zr * r + zg * g + zb * b
        let sum = x + y + z
        guard sum > 0 else { return nil }
        return Chromaticity(x: x / sum, y: y / sum)
    }

    /// The luminance weights this matrix gives R, G and B — its middle row.
    /// Rec.709's are the 0.2126 / 0.7152 / 0.0722 the waveform's luma is
    /// computed with, which is not a coincidence and is pinned as one.
    public var lumaWeights: LinearRGB { LinearRGB(r: yr, g: yg, b: yb) }

    /// The way back: XYZ to linear RGB. nil for a degenerate matrix, which no
    /// real set of primaries produces (three collinear primaries enclose no
    /// gamut) but which a constructor cannot refuse.
    ///
    /// Wanted by the chart's own fill — "what colour IS this chromaticity" is
    /// the inverse question — and derived rather than transcribed so there is
    /// still exactly one statement of Rec.709 in the app.
    public var inverse: XYZToRGB? {
        let determinant = xr * (yg * zb - yb * zg)
            - xg * (yr * zb - yb * zr)
            + xb * (yr * zg - yg * zr)
        guard determinant != 0 else { return nil }
        return XYZToRGB(
            rx: (yg * zb - yb * zg) / determinant,
            ry: (xb * zg - xg * zb) / determinant,
            rz: (xg * yb - xb * yg) / determinant,
            gx: (yb * zr - yr * zb) / determinant,
            gy: (xr * zb - xb * zr) / determinant,
            gz: (xb * yr - xr * yb) / determinant,
            bx: (yr * zg - yg * zr) / determinant,
            by: (xg * zr - xr * zg) / determinant,
            bz: (xr * yg - xg * yr) / determinant)
    }
}

/// The inverse of an `RGBToXYZ` — CIE XYZ back to that space's linear RGB.
public struct XYZToRGB: Sendable, Equatable {
    public let rx: Double, ry: Double, rz: Double
    public let gx: Double, gy: Double, gz: Double
    public let bx: Double, by: Double, bz: Double

    /// Linear RGB for a tristimulus triple. Components come back NEGATIVE for
    /// a colour outside the gamut, and that is information rather than an
    /// error — it is exactly how far outside it is. The caller decides what to
    /// do with it.
    public func linearRGB(_ xyz: XYZColor) -> LinearRGB {
        LinearRGB(r: rx * xyz.x + ry * xyz.y + rz * xyz.z,
                  g: gx * xyz.x + gy * xyz.y + gz * xyz.z,
                  b: bx * xyz.x + by * xyz.y + bz * xyz.z)
    }
}

/// A colour space's primaries and white point, and the RGB→XYZ matrix they
/// define.
///
/// The matrix is DERIVED here rather than transcribed from the standard, and
/// that is the same rule the vectorscope's graticule follows: the chart draws
/// its Rec.709 triangle from these four chromaticities and the analyzer plots
/// samples through a matrix built from the same four, so a corner and the trace
/// that should land on it cannot drift apart. Transcribing the published matrix
/// would give two independent statements of one fact.
///
/// `CIEColorimetryTests` pins the derivation against the matrices ITU-R BT.709
/// and BT.2020 actually print, to four decimals.
public struct ColorPrimaries: Sendable, Equatable {
    public let red: Chromaticity
    public let green: Chromaticity
    public let blue: Chromaticity
    public let white: Chromaticity
    /// Derived in `init`, so a `static let` below pays for the 3×3 solve once
    /// for the life of the process.
    public let rgbToXYZ: RGBToXYZ

    /// The three corners, in the order a triangle is drawn.
    public var triangle: [Chromaticity] { [red, green, blue] }

    public init(red: Chromaticity, green: Chromaticity, blue: Chromaticity,
                white: Chromaticity) {
        self.red = red
        self.green = green
        self.blue = blue
        self.white = white
        rgbToXYZ = Self.matrix(red: red, green: green, blue: blue, white: white)
    }

    /// ITU-R BT.709 (and sRGB): the primaries every SDR signal on a set carries.
    public static let rec709 = ColorPrimaries(
        red: Chromaticity(x: 0.640, y: 0.330),
        green: Chromaticity(x: 0.300, y: 0.600),
        blue: Chromaticity(x: 0.150, y: 0.060),
        white: d65)

    /// ITU-R BT.2020 / BT.2100: what a PQ or HLG signal is required to be on.
    public static let rec2020 = ColorPrimaries(
        red: Chromaticity(x: 0.708, y: 0.292),
        green: Chromaticity(x: 0.170, y: 0.797),
        blue: Chromaticity(x: 0.131, y: 0.046),
        white: d65)

    /// CIE D65, the white point of both — which is why a Rec.709 frame and a
    /// Rec.2020 frame put NEUTRAL on the same spot of the chart and differ
    /// everywhere else.
    public static let d65 = Chromaticity(x: 0.3127, y: 0.3290)

    /// The standard construction: scale each primary's unit-luminance
    /// tristimulus so that R = G = B = 1 comes out exactly on the white point.
    /// Without that scaling the three primaries would be an arbitrary basis and
    /// a neutral frame would land wherever the arithmetic put it.
    ///
    /// The scalars are the solution of `M · s = W` with the primaries as the
    /// columns of M, by Cramer's rule — three 3×3 determinants, which is less
    /// code than an inverse and exact for the only case there is.
    private static func matrix(red: Chromaticity, green: Chromaticity,
                               blue: Chromaticity,
                               white: Chromaticity) -> RGBToXYZ {
        guard let r = red.unitLuminance, let g = green.unitLuminance,
              let b = blue.unitLuminance, let w = white.unitLuminance else {
            return RGBToXYZ(xr: 1, xg: 0, xb: 0, yr: 0, yg: 1, yb: 0,
                            zr: 0, zg: 0, zb: 1)
        }
        let volume = determinant(r, g, b)
        guard volume != 0 else {
            return RGBToXYZ(xr: 1, xg: 0, xb: 0, yr: 0, yg: 1, yb: 0,
                            zr: 0, zg: 0, zb: 1)
        }
        let sr = determinant(w, g, b) / volume
        let sg = determinant(r, w, b) / volume
        let sb = determinant(r, g, w) / volume
        return RGBToXYZ(xr: sr * r.x, xg: sg * g.x, xb: sb * b.x,
                        yr: sr * r.y, yg: sg * g.y, yb: sb * b.y,
                        zr: sr * r.z, zg: sg * g.z, zb: sb * b.z)
    }

    /// Determinant of the 3×3 whose COLUMNS are the three vectors.
    private static func determinant(_ a: XYZColor, _ b: XYZColor,
                                    _ c: XYZColor) -> Double {
        a.x * (b.y * c.z - b.z * c.y)
            - b.x * (a.y * c.z - a.z * c.y)
            + c.x * (a.y * b.z - a.z * b.y)
    }
}

public extension SignalPrimaries {
    /// The chromaticities the signal's codes are stated against.
    ///
    /// This is the per-frame half of the chromaticity chart and the reason the
    /// chart is worth having at all: the SAME code triple means a different
    /// colour under Rec.2020 than under Rec.709, and no other scope in the app
    /// can show that. A waveform, a parade and a vectorscope all plot code
    /// values, which do not change when the primaries do.
    var colorPrimaries: ColorPrimaries {
        switch self {
        case .rec709: return .rec709
        case .rec2020: return .rec2020
        }
    }

    /// The matrix the analyzer plots this frame's samples through.
    var rgbToXYZ: RGBToXYZ { colorPrimaries.rgbToXYZ }
}
