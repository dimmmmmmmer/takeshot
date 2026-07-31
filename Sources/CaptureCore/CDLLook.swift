import Foundation

/// An ASC CDL primary grade: slope, offset and power per channel, plus one
/// saturation. This is what a DIT hands over as a look, and what a `.cc`,
/// `.ccc` or `.cdl` file carries (see `CDLLook+Parse`).
///
/// A look is applied by CONVERTING it to a cube (`cube(size:)`) and letting the
/// existing `CubeLUT` machinery carry it — preview, bake and compare already
/// take a cube, and a second render path for CDL would be a second place for
/// the live picture and the recorded file to disagree. The parameters are kept
/// alongside the generated cube rather than thrown away, because the EDL has to
/// write them back out as `*ASC_SOP`/`*ASC_SAT` and a cube cannot be reduced to
/// nine numbers again.
public struct CDLLook: Equatable, Sendable {
    /// One value per colour channel.
    public struct RGB: Equatable, Sendable {
        public var r: Double
        public var g: Double
        public var b: Double

        public init(_ r: Double, _ g: Double, _ b: Double) {
            self.r = r
            self.g = g
            self.b = b
        }

        public static let one = RGB(1, 1, 1)
        public static let zero = RGB(0, 0, 0)
    }

    /// The `id` attribute of the `ColorCorrection` element, when it had one.
    /// Kept because it is the name the colourist knows the grade by.
    public var id: String
    public var slope: RGB
    public var offset: RGB
    public var power: RGB
    public var saturation: Double

    public init(id: String = "", slope: RGB = .one, offset: RGB = .zero,
                power: RGB = .one, saturation: Double = 1) {
        self.id = id
        self.slope = slope
        self.offset = offset
        self.power = power
        self.saturation = saturation
    }

    /// The identity grade — what a `ColorCorrection` starts as before its file
    /// overrides anything, which is also how a missing `SatNode` reads as 1.
    public static let identity = CDLLook()

    // MARK: - the transfer function

    /// One pixel through the grade: SOP per channel, then saturation.
    ///
    /// `clamp01` before the power is not decoration: `pow` on a negative base
    /// with a fractional exponent is NaN, and a negative offset takes the shadow
    /// end of the input below zero for any grade that lifts contrast.
    public func apply(_ rgb: RGB) -> RGB {
        let shaped = RGB(sop(rgb.r, slope.r, offset.r, power.r),
                         sop(rgb.g, slope.g, offset.g, power.g),
                         sop(rgb.b, slope.b, offset.b, power.b))
        // Rec.709 luma weights: the saturation node is defined against the
        // primaries of the working space, and everything this app shows the
        // operator is tagged 709 (see CubeLUT.makeFilter).
        let luma = 0.2126 * shaped.r + 0.7152 * shaped.g + 0.0722 * shaped.b
        return RGB(Self.clamp01(luma + saturation * (shaped.r - luma)),
                   Self.clamp01(luma + saturation * (shaped.g - luma)),
                   Self.clamp01(luma + saturation * (shaped.b - luma)))
    }

    /// `out = clamp01(in * slope + offset) ^ power`.
    ///
    /// The power is floored just above zero: the ASC note requires a positive
    /// exponent, and a zero one in a hand-written file would make `pow` return 1
    /// for every input — a silently white picture rather than a rejected look.
    /// The floor is applied to the MATH only; the parsed value is what the EDL
    /// writes back, because the export has to say what the file said.
    private func sop(_ value: Double, _ slope: Double, _ offset: Double,
                     _ power: Double) -> Double {
        pow(Self.clamp01(value * slope + offset), max(0.0001, power))
    }

    static func clamp01(_ value: Double) -> Double {
        min(1, max(0, value))
    }

    // MARK: - as a cube

    /// Lattice size the look is rasterized at.
    ///
    /// 65 rather than 33: the grade is a power function, whose curvature is
    /// concentrated in the first lattice cell above black, and trilinear
    /// interpolation across that cell is where all the error lives.
    ///
    /// Measured against direct evaluation at every cell centre of the lattice
    /// (`CDLLookTests.maxError`) for a strong on-set primary — slope
    /// (1.10 1.00 0.90), offset (0.02 0.00 -0.03), power (0.95 1.00 1.15),
    /// saturation 0.85:
    ///
    ///     17³  7.33e-3   1.87 codes at 8 bit
    ///     33³  7.07e-3   1.80 codes at 8 bit
    ///     65³  6.94e-4   0.18 codes at 8 bit, 0.71 at 10 bit
    ///     129³ 4.67e-4
    ///
    /// 33 is wrong by nearly two 8-bit code values in the shadows — visible on
    /// a grade the operator judges exposure by. 65 lands under one code value
    /// at the 10 bits the capture path works in, and the next doubling buys
    /// only a third of that for eight times the memory. 65³ is also the size of
    /// the largest .cube files the app already loads, so nothing downstream
    /// meets a lattice it has not seen.
    public static let cubeSize = 65

    /// The look as a `CubeLUT`, so it flows through every path a .cube does.
    ///
    /// Entry order is red fastest, then green, then blue — the order a .cube
    /// file lists its lines in, which is what `CIColorCube` expects and what
    /// `CubeLUT.parse` therefore produces.
    public func cube(size: Int = CDLLook.cubeSize,
                     name: String? = nil) -> CubeLUT {
        let size = max(2, size)
        let step = 1.0 / Double(size - 1)
        var rgba = [Float]()
        rgba.reserveCapacity(size * size * size * 4)
        for blue in 0..<size {
            for green in 0..<size {
                for red in 0..<size {
                    let out = apply(RGB(Double(red) * step, Double(green) * step,
                                        Double(blue) * step))
                    rgba.append(Float(out.r))
                    rgba.append(Float(out.g))
                    rgba.append(Float(out.b))
                    rgba.append(1)
                }
            }
        }
        let data = rgba.withUnsafeBufferPointer { Data(buffer: $0) }
        return CubeLUT(size: size, data: data,
                       name: name ?? (id.isEmpty ? "CDL" : id))
    }
}
