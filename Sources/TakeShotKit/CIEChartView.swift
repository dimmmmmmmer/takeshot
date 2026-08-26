import CaptureCore
import CoreGraphics
import SwiftUI

/// CIE 1931 chromaticity chart: the frame's colours plotted as (x, y), coloured
/// by their own chromaticity, under a graticule of the spectral locus and the
/// two gamut triangles.
///
/// ## Why 1931 xy and not 1976 u'v'
///
/// u'v' is the perceptually uniform one and several modern tools show it, so
/// this is a choice rather than an omission. xy wins here for one reason that
/// an operator can act on: **it is the space the signal itself is stated in.**
/// Rec.709, Rec.2020 and BT.2100 print their primaries in xy, the camera's
/// manual prints its gamut in xy, the monitor's spec sheet prints its
/// measurement in xy, and the HDR metadata this app already reads off the wire
/// carries the mastering display's primaries in xy too
/// (`HDRStaticMetadata.Chromaticities`). A DIT comparing what is on the chart
/// with what is on the paperwork is comparing the same numbers.
///
/// **What that costs the operator, stated plainly:** 1931 xy is badly
/// non-uniform. Green occupies a third of the diagram and blue is squeezed into
/// a corner, so DISTANCE on this chart is not perceptual difference — two pairs
/// of points the same distance apart can differ by five times as much to the
/// eye. So the chart answers "is this colour inside Rec.709" exactly, and "how
/// far outside is it" only qualitatively. A colourist who needs the second
/// question answered numerically needs ΔE, which is not a scope.
///
/// It is deliberately not offered as a setting. Two charts of the same frame
/// that disagree about which colours look far apart is a question nobody on a
/// set can settle, and the app does not ship a switch whose two positions an
/// operator cannot choose between (see CLAUDE.md, "Settings the app
/// deliberately does not offer").
struct CIEChartView: View {
    let data: ScopeData
    /// Whether the gamut the signal is NOT in is drawn as well.
    var showsOtherGamut = true

    /// Chart colour for every cell of the map, computed once.
    ///
    /// The classic diagram is filled with the colour of each chromaticity, and
    /// that is what makes it readable at a glance: a trace in the green corner
    /// is green. Saturation follows distance from D65 so a near-neutral picture
    /// — which is most pictures — reads as a white cloud on the white point
    /// rather than as a smear of arbitrary hue, exactly as the vectorscope's
    /// hue LUT does around ITS neutral.
    ///
    /// Colours outside sRGB (most of the diagram is) are clipped to the gamut
    /// boundary and then normalized to full brightness, which is what every
    /// printed CIE chart does — the point of the fill is to say WHERE you are,
    /// and no display can show the edges of this diagram truthfully anyway.
    private static let colorLUT: [UInt8] = {
        let size = ScopeData.cieSize
        var lut = [UInt8](repeating: 0, count: size * size * 3)
        guard let matrix = ColorPrimaries.rec709.rgbToXYZ.inverse else {
            return lut
        }
        for row in 0..<size {
            for col in 0..<size {
                let point = chromaticity(col: col, row: row, size: size)
                let rgb = displayRGB(of: point, through: matrix)
                let i = (row * size + col) * 3
                lut[i] = rgb.r
                lut[i + 1] = rgb.g
                lut[i + 2] = rgb.b
            }
        }
        return lut
    }()

    /// The chromaticity at the centre of a map cell — the inverse of
    /// `ScopeData.cieUnit`, so the fill under a trace is the colour of the
    /// chromaticity that trace was deposited at.
    private static func chromaticity(col: Int, row: Int,
                                     size: Int) -> Chromaticity {
        let span = ScopeData.cieSpan
        return Chromaticity(x: (Double(col) + 0.5) / Double(size) * span,
                            y: (1 - (Double(row) + 0.5) / Double(size)) * span)
    }

    /// One chromaticity as a display colour: XYZ at unit luminance back through
    /// the inverse Rec.709 matrix, clipped, normalized, desaturated near the
    /// white point, and gamma-encoded so the fill reads the way a chart does
    /// rather than the way linear light does.
    private static func displayRGB(of point: Chromaticity,
                                   through matrix: XYZToRGB) -> ChartColor {
        guard let xyz = point.unitLuminance else { return ChartColor.black }
        let raw = matrix.linearRGB(xyz)
        let peak = max(raw.r, raw.g, raw.b)
        guard peak > 0 else { return ChartColor.black }
        let white = ColorPrimaries.d65
        let distance = ((point.x - white.x) * (point.x - white.x)
            + (point.y - white.y) * (point.y - white.y)).squareRoot()
        let saturation = min(1.0, distance / 0.09)
        func code(_ value: Double) -> UInt8 {
            let clipped = max(0, value) / peak
            let mixed = (1 - saturation) + clipped * saturation
            return UInt8(max(0, min(255, pow(mixed, 1 / 2.2) * 255)))
        }
        return ChartColor(r: code(raw.r), g: code(raw.g), b: code(raw.b))
    }

    /// One cell of the chart's fill, as the 8-bit codes it is stored as.
    private struct ChartColor {
        let r: UInt8
        let g: UInt8
        let b: UInt8

        static let black = ChartColor(r: 0, g: 0, b: 0)
    }

    /// How much of the box the chart square takes — the vectorscope's number,
    /// and for the vectorscope's reason: the locus runs to the very edge of the
    /// map and a graticule drawn hard against the frame has no gap between the
    /// measurement and the box holding it.
    static let boxFill = 0.94

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height) * Self.boxFill
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            ZStack {
                if let image = ScopeImageCache.image(.cie, from: data) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                        .frame(width: side, height: side)
                        .position(x: center.x, y: center.y)
                }
                CIEGraticule(side: side, center: center,
                             primaries: data.primaries,
                             showsOtherGamut: showsOtherGamut)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // the one scope whose axes are not a signal level, so the box says what
        // it is measuring rather than leaving the operator to infer it from a
        // shape they may only know from a textbook
        .help(L("scope_cie_hint"))
    }

    /// Density map × chart colours → RGBA image, once per analyzed frame
    /// (`ScopeImageCache` holds it for every surface and every re-render).
    static func coloredChart(_ data: ScopeData) -> CGImage? {
        let size = ScopeData.cieSize
        var rgba = [UInt8](repeating: 0, count: size * size * 4)
        let lut = Self.colorLUT
        for i in 0..<(size * size) {
            let density = Int(data.cie[i])
            guard density > 0 else { continue }
            rgba[i * 4] = UInt8(Int(lut[i * 3]) * density / 255)
            rgba[i * 4 + 1] = UInt8(Int(lut[i * 3 + 1]) * density / 255)
            rgba[i * 4 + 2] = UInt8(Int(lut[i * 3 + 2]) * density / 255)
            rgba[i * 4 + 3] = 255
        }
        return rgbaImage(from: rgba, width: size, height: size)
    }
}
