import Foundation

/// The exposure palettes: the two 64³ color cubes the false-color and EL Zone
/// tools remap luma through, and the ramps that define them. Static and shared
/// across every layer — the cubes are built once for the process.
///
/// Split out of `+Assist`, which held both the palettes (this file: what the
/// colors ARE) and the filter stack that puts them over a frame (that file: how
/// they are applied). The two changed for different reasons every time.
extension MetalPreviewLayer {
    /// One entry of an exposure palette. A named type rather than a triple:
    /// three unlabelled Doubles read the same whatever order they are in.
    struct BandColor {
        let red: Double
        let green: Double
        let blue: Double

        init(_ red: Double, _ green: Double, _ blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }
    }

    /// Build a `size³` RGBA cube by mapping each lattice point's luma. All three
    /// cubes below walk the lattice identically; only the mapping differs.
    ///
    /// The input is grayscale (r=g=b on the diagonal), so any weighting would
    /// do — using luma keeps off-axis values sane anyway.
    static func lumaCube(size: Int, _ color: (Double) -> BandColor) -> Data {
        var rgba = [Float]()
        rgba.reserveCapacity(size * size * size * 4)
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let v = (0.2126 * Double(r) + 0.7152 * Double(g)
                        + 0.0722 * Double(b)) / Double(size - 1)
                    let banded = color(v)
                    rgba += [Float(banded.red), Float(banded.green),
                             Float(banded.blue), 1]
                }
            }
        }
        return rgba.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Exposure bands on gamma-encoded code values (ARRI-style palette), as a
    /// ramp of upper bounds. A table rather than a nine-case switch, the same
    /// treatment as `elZoneRamp` below: `nil` is where the gray ramp shows
    /// through instead of a warning color.
    static let falseColorBands: [(upTo: Double, color: BandColor?)] = [
        (0.025, BandColor(0.58, 0.20, 0.75)),     // purple — crushed
        (0.08, BandColor(0.16, 0.34, 0.90)),      // blue — deep shadow
        (0.36, nil),                              // gray ramp
        (0.44, BandColor(0.15, 0.75, 0.25)),      // green — 18% gray
        (0.52, nil),
        (0.58, BandColor(0.95, 0.60, 0.70)),      // pink — skin highlight
        (0.92, nil),
        (0.97, BandColor(0.98, 0.90, 0.20)),      // yellow — near clip
        (.infinity, BandColor(0.95, 0.15, 0.10)), // red — clipped
    ]

    /// The false-color band a display value falls in.
    static func band(_ v: Double) -> BandColor {
        let gray = BandColor(v, v, v)
        guard let band = falseColorBands.first(where: { v < $0.upTo })
        else { return gray }
        return band.color ?? gray
    }

    static let falseColorCube: Data = lumaCube(size: 64) { MetalPreviewLayer.band($0) }

    /// EL Zone-style stops around 18% gray: display luma is linearized with
    /// the inverse BT.709 OETF, zones colored per stop (approximation of the
    /// Ed Lachman scale).
    static let elZoneCube: Data = lumaCube(size: 64) { v in
        let linear = max(1e-6, MetalPreviewLayer.bt709Linear(v))
        return MetalPreviewLayer.zoneColor(log2(linear / 0.18))
    }

    /// Inverse BT.709 OETF.
    static func bt709Linear(_ v: Double) -> Double {
        v < 0.081 ? v / 4.5 : pow((v + 0.099) / 1.099, 1 / 0.45)
    }

    /// The EL Zone scale as a ramp indexed by whole stops from 18% gray, with
    /// the two open ends on the end entries. A table rather than a 13-case
    /// switch: the same values, in the order a reader checks them against the
    /// scale.
    static let elZoneRamp: [BandColor] = [
        BandColor(0.04, 0.04, 0.04),   // ≤ -6: black
        BandColor(0.45, 0.15, 0.65),   // -5: purple
        BandColor(0.15, 0.25, 0.90),   // -4: blue
        BandColor(0.10, 0.60, 0.70),   // -3: teal
        BandColor(0.15, 0.65, 0.25),   // -2: green
        BandColor(0.32, 0.32, 0.32),   // -1: dark gray
        BandColor(0.50, 0.50, 0.50),   // 0: 18% — mid gray
        BandColor(0.68, 0.68, 0.68),   // +1: light gray
        BandColor(0.95, 0.60, 0.65),   // +2: pink
        BandColor(0.95, 0.55, 0.15),   // +3: orange
        BandColor(0.98, 0.72, 0.30),   // +4: light orange
        BandColor(0.98, 0.92, 0.25),   // +5: yellow
        BandColor(1, 1, 1),            // ≥ +6: white
    ]

    static func zoneColor(_ stop: Double) -> BandColor {
        // rounding first makes the ends whole stops too, so clamping to ±6
        // lands "≤ -6" and "≥ +6" on the ramp's first and last entries
        let whole = min(6, max(-6, stop.rounded()))
        return elZoneRamp[Int(whole) + 6]
    }
}
