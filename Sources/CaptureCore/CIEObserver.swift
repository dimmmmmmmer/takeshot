import Foundation

/// A point on the CIE 1931 chromaticity diagram — the (x, y) every colour
/// standard states its primaries in.
///
/// Deliberately NOT a colour: chromaticity says what hue and how saturated,
/// and says nothing at all about how bright. That is the whole reason a
/// chromaticity chart is worth a scope box next to a waveform — the waveform
/// answers the other half.
public struct Chromaticity: Sendable, Equatable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    /// The tristimulus values of this chromaticity at unit luminance (Y = 1).
    /// A chromaticity with y = 0 has no tristimulus at all and answers nil
    /// rather than an infinity that would poison a matrix built from it.
    public var unitLuminance: XYZColor? {
        guard y > 0 else { return nil }
        return XYZColor(x: x / y, y: 1, z: (1 - x - y) / y)
    }
}

/// CIE tristimulus values. `x`, `y` and `z` are the standard's X, Y and Z —
/// lowercase because that is what the house style spells identifiers as, and
/// the only place the distinction from a `Chromaticity`'s x and y could bite
/// is here, where it is said out loud.
public struct XYZColor: Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }
}

/// A linear (NOT gamma-encoded) RGB triple, in whatever units the caller's
/// transfer put it in. A type rather than a tuple because it travels in and out
/// of the matrices below and a triple of unlabelled Doubles is exactly how a
/// red and a blue end up swapped.
public struct LinearRGB: Sendable, Equatable {
    public let r: Double
    public let g: Double
    public let b: Double

    public init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }
}

/// One wavelength of the CIE 1931 2° standard colorimetric observer.
public struct SpectralSample: Sendable, Equatable {
    public let nanometres: Int
    /// The colour matching functions x̄(λ), ȳ(λ), z̄(λ).
    public let xBar: Double
    public let yBar: Double
    public let zBar: Double

    /// Where this wavelength sits on the diagram — a point of the spectral
    /// locus, i.e. the most saturated colour that wavelength can be.
    public var chromaticity: Chromaticity {
        let sum = xBar + yBar + zBar
        guard sum > 0 else { return Chromaticity(x: 0, y: 0) }
        return Chromaticity(x: xBar / sum, y: yBar / sum)
    }
}

/// The CIE 1931 2° standard colorimetric observer, and the spectral locus it
/// defines.
///
/// **Provenance.** The colour matching functions below are the CIE 1931 2°
/// standard observer at 5 nm intervals, as published by the CIE and reprinted
/// in Wyszecki & Stiles, *Color Science* (2nd ed.), Table I(3.3.1) — the same
/// table ITU-R BT.709 and BT.2020 state their primaries against. Typed as
/// x̄, ȳ, z̄ triples; nothing here is fitted, smoothed or interpolated.
///
/// The table runs 380–700 nm and the CIE's continues to 780. The tail is left
/// out on purpose rather than truncated by accident: past 700 nm every
/// tristimulus value is under 1 % of the peak and the chromaticity is the same
/// point to three decimals (0.7347, 0.2653), so the extra 16 rows draw a
/// horseshoe tip that wobbles on rounding noise and nothing else. What the
/// locus is FOR here is a graticule.
///
/// Three known points check the typing on their own, and `CIEColorimetryTests`
/// asserts them: 520 nm is the top of the horseshoe at (0.0743, 0.8338),
/// 700 nm its red end at (0.7347, 0.2653), and 505 nm its leftmost point at
/// x = 0.0039.
public enum CIE1931 {
    /// x̄, ȳ, z̄ at 5 nm from 380 nm, three to a row.
    private static let table: [Double] = [
        0.001368, 0.000039, 0.006450, // 380
        0.002236, 0.000064, 0.010550, // 385
        0.004243, 0.000120, 0.020050, // 390
        0.007650, 0.000217, 0.036210, // 395
        0.014310, 0.000396, 0.067850, // 400
        0.023190, 0.000640, 0.110200, // 405
        0.043510, 0.001210, 0.207400, // 410
        0.077630, 0.002180, 0.371300, // 415
        0.134380, 0.004000, 0.645600, // 420
        0.214770, 0.007300, 1.039050, // 425
        0.283900, 0.011600, 1.385600, // 430
        0.328500, 0.016840, 1.622960, // 435
        0.348280, 0.023000, 1.747060, // 440
        0.348060, 0.029800, 1.782600, // 445
        0.336200, 0.038000, 1.772110, // 450
        0.318700, 0.048000, 1.744100, // 455
        0.290800, 0.060000, 1.669200, // 460
        0.251100, 0.073900, 1.528100, // 465
        0.195360, 0.090980, 1.287640, // 470
        0.142100, 0.112600, 1.041900, // 475
        0.095640, 0.139020, 0.812950, // 480
        0.057950, 0.169300, 0.616200, // 485
        0.032010, 0.208020, 0.465180, // 490
        0.014700, 0.258600, 0.353300, // 495
        0.004900, 0.323000, 0.272000, // 500
        0.002400, 0.407300, 0.212300, // 505
        0.009300, 0.503000, 0.158200, // 510
        0.029100, 0.608200, 0.111700, // 515
        0.063270, 0.710000, 0.078250, // 520
        0.109600, 0.793200, 0.057250, // 525
        0.165500, 0.862000, 0.042160, // 530
        0.225750, 0.914850, 0.029840, // 535
        0.290400, 0.954000, 0.020300, // 540
        0.359700, 0.980300, 0.013400, // 545
        0.433450, 0.994950, 0.008750, // 550
        0.512050, 1.000000, 0.005750, // 555
        0.594500, 0.995000, 0.003900, // 560
        0.678400, 0.978600, 0.002750, // 565
        0.762100, 0.952000, 0.002100, // 570
        0.842500, 0.915400, 0.001800, // 575
        0.916300, 0.870000, 0.001650, // 580
        0.978600, 0.816300, 0.001400, // 585
        1.026300, 0.757000, 0.001100, // 590
        1.056700, 0.694900, 0.001000, // 595
        1.062200, 0.631000, 0.000800, // 600
        1.045600, 0.566800, 0.000600, // 605
        1.002600, 0.503000, 0.000340, // 610
        0.938400, 0.441200, 0.000240, // 615
        0.854450, 0.381000, 0.000190, // 620
        0.751400, 0.321000, 0.000100, // 625
        0.642400, 0.265000, 0.000050, // 630
        0.541900, 0.217000, 0.000030, // 635
        0.447900, 0.175000, 0.000020, // 640
        0.360800, 0.138200, 0.000010, // 645
        0.283500, 0.107000, 0.000000, // 650
        0.218700, 0.081600, 0.000000, // 655
        0.164900, 0.061000, 0.000000, // 660
        0.121200, 0.044580, 0.000000, // 665
        0.087400, 0.032000, 0.000000, // 670
        0.063600, 0.023200, 0.000000, // 675
        0.046770, 0.017000, 0.000000, // 680
        0.032900, 0.011920, 0.000000, // 685
        0.022700, 0.008210, 0.000000, // 690
        0.015840, 0.005723, 0.000000, // 695
        0.011359, 0.004102, 0.000000, // 700
    ]

    /// The first wavelength in the table, nm.
    public static let firstWavelength = 380
    /// The step between rows, nm.
    public static let wavelengthStep = 5

    /// The observer, one entry per wavelength.
    public static let observer: [SpectralSample] = (0..<(table.count / 3))
        .map { index in
            SpectralSample(
                nanometres: firstWavelength + index * wavelengthStep,
                xBar: table[index * 3],
                yBar: table[index * 3 + 1],
                zBar: table[index * 3 + 2])
        }

    /// The horseshoe: the chromaticity of every wavelength in the table, in
    /// order. Closing it from the last point back to the first is the line of
    /// purples, which is a line rather than a curve because no single
    /// wavelength produces a purple at all.
    public static let spectralLocus: [Chromaticity] =
        observer.map(\.chromaticity)

    /// The locus point of a wavelength in the table, for the marks a graticule
    /// puts on the horseshoe. nil for anything the table does not carry —
    /// interpolating would invent a standard observer between two published
    /// rows.
    public static func locusPoint(atWavelength nanometres: Int) -> Chromaticity? {
        observer.first { $0.nanometres == nanometres }?.chromaticity
    }
}
