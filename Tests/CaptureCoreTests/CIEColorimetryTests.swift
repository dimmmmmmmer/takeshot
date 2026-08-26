import Foundation
import Testing

@testable import CaptureCore

/// The colorimetry the chromaticity chart is built on: the standard observer,
/// the RGB→XYZ matrices derived from each gamut's primaries, and the inverse
/// transfer that turns a wire code back into linear light.
///
/// Every number here is checked against something OUTSIDE this codebase — a
/// published locus point, a published matrix, a published reference level — for
/// one reason: a chromaticity chart computed with the wrong curve or the wrong
/// matrix still looks exactly like a chromaticity chart. There is no way to
/// spot it by looking, so it has to be spotted by arithmetic.
struct CIEColorimetryTests {
    // MARK: - the standard observer

    /// Three points of the spectral locus everyone who has drawn one knows by
    /// heart, and between them they check the whole table: the top of the
    /// horseshoe, its red end, and its leftmost point.
    @Test func theSpectralLocusHasItsPublishedExtremes() throws {
        let green: Chromaticity = try #require(
            CIE1931.locusPoint(atWavelength: 520),
            "520 nm is not in the observer table")
        #expect(abs(green.x - 0.0743) < 0.0002, "520 nm x is \(green.x)")
        #expect(abs(green.y - 0.8338) < 0.0002, "520 nm y is \(green.y)")

        let red: Chromaticity = try #require(
            CIE1931.locusPoint(atWavelength: 700),
            "700 nm is not in the observer table")
        #expect(abs(red.x - 0.7347) < 0.0002, "700 nm x is \(red.x)")
        #expect(abs(red.y - 0.2653) < 0.0002, "700 nm y is \(red.y)")

        let leftmost: Chromaticity = try #require(
            CIE1931.locusPoint(atWavelength: 505),
            "505 nm is not in the observer table")
        #expect(abs(leftmost.x - 0.0039) < 0.0002,
                "505 nm x is \(leftmost.x)")
    }

    /// The whole locus fits the square the map covers, which is what makes the
    /// chart's domain a decision rather than a hope: a horseshoe clipped by the
    /// map would be a graticule that lies about where colour ends.
    @Test func theWholeLocusFitsTheMapsSquare() {
        let span: Double = ScopeData.cieSpan
        let outside: [Chromaticity] = CIE1931.spectralLocus.filter {
            $0.x < 0 || $0.y < 0 || $0.x > span || $0.y > span
        }
        #expect(outside.isEmpty,
                "\(outside.count) locus points fall outside 0…\(span)")
        #expect(CIE1931.spectralLocus.count == 65,
                "the table has \(CIE1931.spectralLocus.count) rows, not 65")
    }

    // MARK: - the matrices, against the ones the standards print

    /// ITU-R BT.709's own RGB→XYZ matrix, to four decimals — derived here from
    /// the four chromaticities rather than transcribed, so this is the check
    /// that the derivation is the standard construction and not merely a
    /// plausible one.
    @Test func theRec709MatrixIsTheOneTheStandardPrints() {
        let m: RGBToXYZ = ColorPrimaries.rec709.rgbToXYZ
        let published: [Double] = [0.4124, 0.3576, 0.1805,
                                   0.2126, 0.7152, 0.0722,
                                   0.0193, 0.1192, 0.9505]
        let derived: [Double] = [m.xr, m.xg, m.xb,
                                 m.yr, m.yg, m.yb,
                                 m.zr, m.zg, m.zb]
        for index: Int in published.indices {
            #expect(abs(derived[index] - published[index]) < 0.0001,
                    "entry \(index): derived \(derived[index]), BT.709 prints \(published[index])")
        }
    }

    /// And BT.2020's, which is the one that matters for the feature: a
    /// Rec.2020 frame's codes are put on the chart through THIS.
    @Test func theRec2020MatrixIsTheOneTheStandardPrints() {
        let m: RGBToXYZ = ColorPrimaries.rec2020.rgbToXYZ
        let published: [Double] = [0.636958, 0.144617, 0.168881,
                                   0.262700, 0.677998, 0.059302,
                                   0.000000, 0.028073, 1.060985]
        let derived: [Double] = [m.xr, m.xg, m.xb,
                                 m.yr, m.yg, m.yb,
                                 m.zr, m.zg, m.zb]
        for index: Int in published.indices {
            #expect(abs(derived[index] - published[index]) < 0.0001,
                    "entry \(index): derived \(derived[index]), BT.2020 prints \(published[index])")
        }
    }

    /// The middle row of the Rec.709 matrix IS the luma the waveform is drawn
    /// with. Two parts of the app that were written years apart from two
    /// different sources, and they have to be the same three numbers or the
    /// chart and the waveform disagree about what grey is.
    @Test func theLumaWeightsAreTheWaveformsOwn() {
        let weights: LinearRGB = ColorPrimaries.rec709.rgbToXYZ.lumaWeights
        #expect(abs(weights.r - 0.2126) < 0.0001, "red weight \(weights.r)")
        #expect(abs(weights.g - 0.7152) < 0.0001, "green weight \(weights.g)")
        #expect(abs(weights.b - 0.0722) < 0.0001, "blue weight \(weights.b)")
    }

    /// R = G = B lands on the white point exactly, in both gamuts — which is
    /// the whole reason the primaries are scaled at all. Without it a neutral
    /// picture would plot wherever the arithmetic put it, and the cross the
    /// operator judges white balance against would mean nothing.
    @Test func aNeutralTripleLandsExactlyOnD65() throws {
        for gamut: ColorPrimaries in [.rec709, .rec2020] {
            let white: Chromaticity = try #require(
                gamut.rgbToXYZ.chromaticity(r: 1, g: 1, b: 1),
                "a neutral triple has no chromaticity at all")
            #expect(abs(white.x - ColorPrimaries.d65.x) < 1e-9,
                    "neutral x is \(white.x)")
            #expect(abs(white.y - ColorPrimaries.d65.y) < 1e-9,
                    "neutral y is \(white.y)")
        }
    }

    /// A full-amplitude primary lands on its own corner, in both gamuts —
    /// which is what lets the graticule's triangle be drawn from the same four
    /// chromaticities the matrix is derived from and still be right.
    @Test func aPrimaryLandsOnItsOwnCorner() throws {
        for gamut: ColorPrimaries in [.rec709, .rec2020] {
            let corners: [Chromaticity] = gamut.triangle
            let plotted: [Chromaticity?] = [
                gamut.rgbToXYZ.chromaticity(r: 1, g: 0, b: 0),
                gamut.rgbToXYZ.chromaticity(r: 0, g: 1, b: 0),
                gamut.rgbToXYZ.chromaticity(r: 0, g: 0, b: 1),
            ]
            for index: Int in corners.indices {
                let point: Chromaticity = try #require(
                    plotted[index], "a pure primary has no chromaticity")
                #expect(abs(point.x - corners[index].x) < 1e-9,
                        "corner \(index) x: \(point.x) vs \(corners[index].x)")
                #expect(abs(point.y - corners[index].y) < 1e-9,
                        "corner \(index) y: \(point.y) vs \(corners[index].y)")
            }
        }
    }

    /// Black has no chromaticity, and the matrix says so rather than dividing
    /// by zero. Every frame has thousands of these samples.
    @Test func blackHasNoChromaticityAtAll() {
        #expect(ColorPrimaries.rec709.rgbToXYZ.chromaticity(r: 0, g: 0, b: 0)
            == nil)
    }

    /// The inverse round-trips — it is what the chart's own fill colours are
    /// computed through, and a wrong inverse would tint the whole diagram
    /// without moving a single trace.
    @Test func theInverseMatrixRoundTrips() throws {
        let forward: RGBToXYZ = ColorPrimaries.rec709.rgbToXYZ
        let back: XYZToRGB = try #require(forward.inverse,
                                          "Rec.709 has no invertible matrix")
        let samples: [LinearRGB] = [LinearRGB(r: 1, g: 0, b: 0),
                                    LinearRGB(r: 0.2, g: 0.7, b: 0.4),
                                    LinearRGB(r: 1, g: 1, b: 1)]
        for sample: LinearRGB in samples {
            let x: Double = forward.xr * sample.r + forward.xg * sample.g
                + forward.xb * sample.b
            let y: Double = forward.yr * sample.r + forward.yg * sample.g
                + forward.yb * sample.b
            let z: Double = forward.zr * sample.r + forward.zg * sample.g
                + forward.zb * sample.b
            let round: LinearRGB = back.linearRGB(
                XYZColor(x: x, y: y, z: z))
            #expect(abs(round.r - sample.r) < 1e-9, "r \(round.r)")
            #expect(abs(round.g - sample.g) < 1e-9, "g \(round.g)")
            #expect(abs(round.b - sample.b) < 1e-9, "b \(round.b)")
        }
    }

    // MARK: - the inverse transfer, per curve

    /// SDR: BT.1886 at gamma 2.4, so half the signal range is 0.5^2.4 of the
    /// light. Pinned against the power computed by hand, not against a second
    /// call into the source.
    @Test func theSDRCurveIsBT1886AtGammaTwoPointFour() {
        #expect(abs(SignalTransfer.sdr.linearLight(forSignal: 0.5) - 0.1894646)
            < 1e-6,
                "half signal is \(SignalTransfer.sdr.linearLight(forSignal: 0.5)) of white")
        #expect(abs(SignalTransfer.sdr.linearLight(forSignal: 1) - 1) < 1e-12,
                "signal 1 is not display white")
        #expect(SignalTransfer.sdr.linearLight(forSignal: 0) == 0)
    }

    /// A sub-black excursion floors at zero — negative light is not a colour —
    /// and a super-white excursion does NOT clip: it is a real code the camera
    /// sent, and folding it onto white would desaturate a bright highlight on
    /// the chart with nothing saying so.
    @Test func theSDRCurveFloorsBelowBlackAndRidesAboveWhite() {
        #expect(SignalTransfer.sdr.linearLight(forSignal: -0.07) == 0,
                "a sub-black sample produced light")
        let superWhite: Double = SignalTransfer.sdr.linearLight(forSignal: 1.09)
        #expect(superWhite > 1.2,
                "a super-white sample was clipped to \(superWhite)")
    }

    /// PQ: ST 2084 is absolute, so half of its signal range is about
    /// 92.2 cd/m² — a value the five published constants give and this app's
    /// display half never sees, since it is far below diffuse white.
    @Test func thePQCurveIsAbsoluteST2084() {
        let half: Double = SignalTransfer.pq.linearLight(forSignal: 0.5)
            * HDRTransfer.referenceWhiteNits
        #expect(abs(half - 92.2) < 0.5, "PQ 0.5 came out at \(half) cd/m²")
        let top: Double = SignalTransfer.pq.linearLight(forSignal: 1)
            * HDRTransfer.referenceWhiteNits
        #expect(abs(top - 10_000) < 1, "PQ 1.0 came out at \(top) cd/m²")
        #expect(SignalTransfer.pq.linearLight(forSignal: 0) < 1e-6,
                "PQ 0 is not black")
    }

    /// HLG: through the BT.2100 OOTF, so its two BT.2408 reference levels land
    /// where BT.2408 says — diffuse white at signal 0.75 and the 18 % grey card
    /// at 0.38. This is what makes an HLG frame and a PQ frame of the same
    /// scene plot on the same spot instead of on two.
    @Test func theHLGCurveLandsOnBT2408sReferenceLevels() {
        let white: Double = SignalTransfer.hlg.linearLight(forSignal: 0.75)
        #expect(abs(white - 1) < 0.01,
                "HLG 0.75 is \(white) of diffuse white, not 1")
        let grey: Double = SignalTransfer.hlg.linearLight(forSignal: 0.38)
            * HDRTransfer.referenceWhiteNits
        #expect(abs(grey - HDRTransfer.referenceGreyNits) < 0.5,
                "HLG 0.38 is \(grey) cd/m², not BT.2408's 26")
    }

    /// The three curves agree about diffuse white, which is the property that
    /// keeps the chart still when a camera switches transfer mid-shot: the same
    /// picture is the same colours, whatever it is encoded with.
    @Test func allThreeCurvesAgreeAboutDiffuseWhite() {
        #expect(abs(SignalTransfer.sdr.linearLight(forSignal: 1) - 1) < 0.01)
        let pqWhite: Double = SignalTransfer.pq.linearLight(
            forSignal: HDRTransfer.pqSignal(HDRTransfer.referenceWhiteNits))
        #expect(abs(pqWhite - 1) < 0.001, "PQ diffuse white is \(pqWhite)")
        #expect(abs(SignalTransfer.hlg.linearLight(forSignal: 0.75) - 1) < 0.01)
    }
}
