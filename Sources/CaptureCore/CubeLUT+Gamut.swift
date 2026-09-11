import Foundation

/// **A gamut conversion, built as a cube.**
///
/// Rec.2020 codes and Rec.709 codes are different colours, and a proxy made
/// from a wide-gamut take used to say so honestly: it carried the camera's
/// codes and stated Rec.2020 primaries under a Rec.709 curve, which a
/// colour-managed player converts exactly and for free. What everything ELSE
/// does with it is show a picture too saturated to judge — an editorial tool
/// that ignores the tag, a browser preview, a phone. A daily is watched by
/// whatever is to hand, which is why the owner asked for 1-1-1 "полюбас": the
/// file has to be Rec.709 in its codes, not only in what it is willing to say.
///
/// There is nothing invented here — it is the textbook conversion: linearize,
/// to XYZ through the source's own matrix, back through the target's inverse,
/// clip, re-encode. What makes it affordable is the SHAPE: the dailies
/// composer already applies a `.cube` for the baked look, so expressed as a
/// cube a gamut conversion joins that stage instead of adding a per-pixel
/// matrix in linear light to the frame path (`DailiesFrameComposer.graded`).
///
/// Both matrices come from `ColorPrimaries`, derived from the four
/// chromaticities, so the conversion and the chromaticity chart that shows an
/// operator where those primaries ARE cannot come to disagree.
extension CubeLUT {
    /// **The lattice, chosen by measurement rather than by habit.**
    ///
    /// On a lattice point the cube IS the conversion; between points it is
    /// trilinear interpolation of a function that is a matrix in LIGHT indexed
    /// by CODES, and the re-encode has an infinite slope at zero — so the
    /// error is nothing at all over most of the cube and rises on saturated
    /// colours with a channel near black. Worst / 99th percentile / median CIE
    /// xy error, over a grid deliberately placed BETWEEN lattice points, for
    /// colours above 10 % code (`GamutCubeTests.theLatticeIsFineEnough`):
    ///
    /// | | worst | p99 | median | built |
    /// | --- | --- | --- | --- | --- |
    /// | 33³ | 0.0073 | 0.0033 | 0.00019 | 9.5 ms |
    /// | 65³ | 0.0030 | 0.0010 | 0.00004 | 69 ms |
    ///
    /// A vectorscope target box is about 0.02 across in xy, so the typical
    /// colour is untouched either way and the tail is what separates them: a
    /// third of a box against a seventh. 65 costs 60 ms and 4.4 MB ONCE PER
    /// CLIP — against a transcode measured in seconds to minutes — and colour
    /// accuracy ranks with reliability in this app, so the tail is what it is
    /// bought with.
    static let gamutLattice = 65

    /// BT.1886, gamma 2.4 — the exact inverse of the last step of the display
    /// transform (`HDRTransfer`), which is what put the codes this cube is
    /// indexed by where they are. The chromaticity chart linearizes SDR codes
    /// through the same exponent for the same reason, and it is deliberately
    /// NOT the camera OETF: that one answers about scene light and differs by
    /// the OOTF, a per-channel power that MOVES a saturated colour.
    static let displayGamma = 2.4

    /// **The one conversion this app actually makes, built once.**
    ///
    /// A batch is forty takes off one camera, so building the identical cube
    /// per item would pay its 69 ms and its 4.4 MB forty times over. Lazily,
    /// like every `static let`: a session that renders no wide-gamut dailies
    /// never builds it at all, and one that renders thirty builds it once.
    static let rec2020ToRec709 = gamut(from: .rec2020, to: .rec709,
                                       name: "Rec.2020 → Rec.709")

    /// A cube that takes gamma-encoded codes on `source`'s primaries to the
    /// same colours on `target`'s.
    ///
    /// nil only for a degenerate matrix — three collinear primaries enclose no
    /// gamut and cannot be inverted — which no real set produces and a
    /// constructor cannot refuse.
    static func gamut(from source: ColorPrimaries, to target: ColorPrimaries,
                      size: Int = gamutLattice,
                      name: String = "gamut") -> CubeLUT? {
        guard size >= 2, size <= maximumSize,
              let fromXYZ = target.rgbToXYZ.inverse else { return nil }
        let toXYZ = source.rgbToXYZ
        let last = Double(size - 1)
        var rgba = [Float]()
        rgba.reserveCapacity(size * size * size * 4)
        // RED fastest, then green, then blue: the order a `.cube` file states
        // its entries in, which is the order `parse` hands to CIColorCube
        // untouched. A cube built here and one read off disk go through the
        // same filter, so there is one order and not two.
        for blue in 0..<size {
            for green in 0..<size {
                for red in 0..<size {
                    let light = LinearRGB(r: linearized(Double(red) / last),
                                          g: linearized(Double(green) / last),
                                          b: linearized(Double(blue) / last))
                    let converted = fromXYZ.linearRGB(toXYZ.tristimulus(light))
                    rgba.append(Float(encoded(converted.r)))
                    rgba.append(Float(encoded(converted.g)))
                    rgba.append(Float(encoded(converted.b)))
                    rgba.append(1)
                }
            }
        }
        let data = rgba.withUnsafeBufferPointer { Data(buffer: $0) }
        return CubeLUT(size: size, data: data, name: name)
    }

    /// A code value as light.
    static func linearized(_ code: Double) -> Double {
        pow(max(0, code), displayGamma)
    }

    /// Light back as a code, **clipped** — and that clip is the whole cost of
    /// this conversion, so it is stated here rather than buried.
    ///
    /// A colour outside the target gamut comes back with a negative component
    /// (it needs more than the target's primaries can make) or one over unity,
    /// and the clip puts it on the boundary: a Rec.2020 laser green lands on
    /// Rec.709's green corner, and two such greens land on the same one. That
    /// is a review proxy's own trade — the alternative is a gamut COMPRESSION,
    /// which moves colours that were always inside the gamut in order to keep
    /// the ones outside it apart, and a daily is judged against a monitor
    /// showing the untouched original. Clipping leaves everything a Rec.709
    /// display could show exactly where it was.
    static func encoded(_ light: Double) -> Double {
        pow(min(1, max(0, light)), 1 / displayGamma)
    }
}
