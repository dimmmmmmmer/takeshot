import CoreVideo
import Foundation
import Testing

@testable import CaptureCore

/// The CIE chromaticity map the analyzer fills in the same grid walk as the
/// waveform, the parade, the histogram and the vectorscope.
///
/// Two things can be wrong here in a way that is invisible on screen, and both
/// have their own tests below: computing the chromaticity from the GAMMA-ENCODED
/// codes instead of from linear light, and computing it against a fixed set of
/// primaries instead of the frame's own. Either mistake produces a chart that
/// looks exactly like a working chart, with every colour in the wrong place.
struct ScopeCIETests {
    /// One pixel's wire codes.
    /// The chromaticity of a cell of the map — the inverse of
    /// `ScopeData.cieUnit`, which is what the analyzer deposits through.
    private func chromaticity(ofCell index: Int) -> Chromaticity {
        let size: Int = ScopeData.cieSize
        let span: Double = ScopeData.cieSpan
        let col: Double = Double(index % size) + 0.5
        let row: Double = Double(index / size) + 0.5
        return Chromaticity(x: col / Double(size) * span,
                            y: (1 - row / Double(size)) * span)
    }

    /// Where the trace is: the chromaticity of the brightest cell.
    private func peak(_ data: ScopeData) -> Chromaticity {
        var best: Int = 0
        for index: Int in data.cie.indices where data.cie[index] > data.cie[best] {
            best = index
        }
        return chromaticity(ofCell: best)
    }

    /// One map cell, in xy units — the resolution any position here is measured
    /// to, and therefore the unit every tolerance below is stated in.
    private static let cell: Double =
        ScopeData.cieSpan / Double(ScopeData.cieSize)

    private func analyzed(r: Int, g: Int, b: Int,
                          levels: ScopeWireLevels = .limited,
                          colorimetry: WireColorimetry = .sdr) throws
        -> ScopeData {
        let frame: CVPixelBuffer = try R210Fixtures.make(r: r, g: g, b: b)
        return try #require(
            ScopeAnalyzer.analyze(frame, wireLevels: levels,
                                  colorimetry: colorimetry),
            "the analyzer refused an r210 frame")
    }

    /// Nominal black and white in 10-bit studio swing, and the code halfway
    /// between them — the levels the wire actually carries.
    private static let black: Int = 64
    private static let white: Int = 940
    private static let half: Int = 502

    // MARK: - linear light, not code values

    /// The test the whole feature turns on.
    ///
    /// A frame of R = 100 %, G = 50 %, B = 0 % has one chromaticity if the
    /// codes are linearized first and a different one if they are not, and both
    /// are perfectly plausible points on the diagram. Measured, they are 0.075
    /// apart in x — twenty-two cells of this map — so nothing about the
    /// tolerance is doing the work here.
    ///
    /// Both candidates are computed through the SAME matrix, so the only
    /// variable is the curve.
    @Test func theChromaticityIsComputedFromLinearLightAndNotFromTheCodes()
        throws {
        let data: ScopeData = try analyzed(r: Self.white, g: Self.half,
                                           b: Self.black)
        let matrix: RGBToXYZ = ColorPrimaries.rec709.rgbToXYZ
        let linear: Chromaticity = try #require(
            matrix.chromaticity(r: 1, g: pow(0.5, 2.4), b: 0),
            "the linearized triple has no chromaticity")
        let naive: Chromaticity = try #require(
            matrix.chromaticity(r: 1, g: 0.5, b: 0),
            "the un-linearized triple has no chromaticity")
        let plotted: Chromaticity = peak(data)
        #expect(abs(plotted.x - linear.x) < 2 * Self.cell,
                "plotted x \(plotted.x), linear light says \(linear.x)")
        #expect(abs(plotted.y - linear.y) < 2 * Self.cell,
                "plotted y \(plotted.y), linear light says \(linear.y)")
        #expect(abs(plotted.x - naive.x) > 10 * Self.cell,
                "plotted x \(plotted.x) sits on the un-linearized \(naive.x)")
    }

    /// What the codes MEAN as a signal is the levels reading, and it reaches
    /// the chart: the same buffer read as studio swing and as full range is two
    /// different colours. A limited frame read as full puts nominal black at
    /// signal 0.063, whose 2.4 power is not zero, and every dark component then
    /// drifts toward the white point.
    @Test func theLevelsReadingChangesWhereTheColourLands() throws {
        let limited: Chromaticity = peak(
            try analyzed(r: Self.white, g: Self.half, b: Self.black,
                         levels: .limited))
        let full: Chromaticity = peak(
            try analyzed(r: Self.white, g: Self.half, b: Self.black,
                         levels: .full))
        let distance: Double = ((limited.x - full.x) * (limited.x - full.x)
            + (limited.y - full.y) * (limited.y - full.y)).squareRoot()
        #expect(distance > 4 * Self.cell,
                "the levels reading moved the colour by \(distance / Self.cell) cells")
    }

    /// A PQ frame is linearized through PQ. Same codes, same primaries, and the
    /// curve alone moves the colour — which is what "the chart reads the
    /// signal's own transfer" means as a measurement rather than as a claim.
    @Test func aPQFrameIsLinearizedThroughItsOwnCurve() throws {
        let sdr: Chromaticity = peak(
            try analyzed(r: Self.white, g: Self.half, b: Self.black,
                         colorimetry: WireColorimetry(transfer: .sdr,
                                                      primaries: .rec709)))
        let pq: Chromaticity = peak(
            try analyzed(r: Self.white, g: Self.half, b: Self.black,
                         colorimetry: WireColorimetry(transfer: .pq,
                                                      primaries: .rec709)))
        let distance: Double = ((sdr.x - pq.x) * (sdr.x - pq.x)
            + (sdr.y - pq.y) * (sdr.y - pq.y)).squareRoot()
        #expect(distance > 4 * Self.cell,
                "PQ and SDR plotted the same codes \(distance / Self.cell) cells apart")
        let expected: Chromaticity = try #require(
            ColorPrimaries.rec709.rgbToXYZ.chromaticity(
                r: SignalTransfer.pq.linearLight(forSignal: 1),
                g: SignalTransfer.pq.linearLight(forSignal: 0.5),
                b: SignalTransfer.pq.linearLight(forSignal: 0)),
            "the PQ triple has no chromaticity")
        #expect(abs(pq.x - expected.x) < 2 * Self.cell,
                "PQ plotted x \(pq.x), its own curve says \(expected.x)")
        #expect(abs(pq.y - expected.y) < 2 * Self.cell,
                "PQ plotted y \(pq.y), its own curve says \(expected.y)")
    }

    // MARK: - the primaries are per frame

    /// The same codes under Rec.709 and under Rec.2020 are DIFFERENT colours,
    /// and each lands on its own gamut's corner. This is the thing no other
    /// scope in the app can show: a waveform, a parade and a vectorscope all
    /// plot code values, and code values do not move when the primaries do.
    @Test func theSameCodesLandOnDifferentPointsUnderDifferentPrimaries()
        throws {
        let sevenNine: Chromaticity = peak(
            try analyzed(r: Self.white, g: Self.black, b: Self.black,
                         colorimetry: WireColorimetry(transfer: .sdr,
                                                      primaries: .rec709)))
        let twenty: Chromaticity = peak(
            try analyzed(r: Self.white, g: Self.black, b: Self.black,
                         colorimetry: WireColorimetry(transfer: .sdr,
                                                      primaries: .rec2020)))
        let red709: Chromaticity = ColorPrimaries.rec709.red
        let red2020: Chromaticity = ColorPrimaries.rec2020.red
        #expect(abs(sevenNine.x - red709.x) < 2 * Self.cell,
                "full red on a 709 frame plotted at x \(sevenNine.x), corner \(red709.x)")
        #expect(abs(sevenNine.y - red709.y) < 2 * Self.cell,
                "full red on a 709 frame plotted at y \(sevenNine.y), corner \(red709.y)")
        #expect(abs(twenty.x - red2020.x) < 2 * Self.cell,
                "full red on a 2020 frame plotted at x \(twenty.x), corner \(red2020.x)")
        #expect(abs(twenty.y - red2020.y) < 2 * Self.cell,
                "full red on a 2020 frame plotted at y \(twenty.y), corner \(red2020.y)")
        let distance: Double = ((sevenNine.x - twenty.x) * (sevenNine.x - twenty.x)
            + (sevenNine.y - twenty.y) * (sevenNine.y - twenty.y)).squareRoot()
        #expect(distance > 10 * Self.cell,
                "the two gamuts put the same codes \(distance / Self.cell) cells apart")
    }

    /// Which corner a primary lands on is a fact about the PRIMARIES and not
    /// about the curve, so a PQ Rec.2020 frame — the combination a real HDR
    /// camera sends — lands on the same 2020 corner as an SDR one.
    @Test func aPQRec2020FrameStillLandsOnTheRec2020Corner() throws {
        let plotted: Chromaticity = peak(
            try analyzed(r: Self.white, g: Self.black, b: Self.black,
                         colorimetry: WireColorimetry(transfer: .pq,
                                                      primaries: .rec2020)))
        let corner: Chromaticity = ColorPrimaries.rec2020.red
        #expect(abs(plotted.x - corner.x) < 2 * Self.cell,
                "PQ 2020 red plotted at x \(plotted.x), corner \(corner.x)")
        #expect(abs(plotted.y - corner.y) < 2 * Self.cell,
                "PQ 2020 red plotted at y \(plotted.y), corner \(corner.y)")
    }

    /// The frame's primaries ride out on the data, because the graticule has to
    /// draw the triangle the map was computed against — a chart labelled 2020
    /// over a 709 map is the one error nobody looking at it can catch.
    @Test func theFramesPrimariesRideOutOnTheData() throws {
        let sdr: ScopeData = try analyzed(r: 500, g: 500, b: 500)
        #expect(sdr.primaries == .rec709, "an SDR frame is not Rec.709")
        let wide: ScopeData = try analyzed(
            r: 500, g: 500, b: 500,
            colorimetry: WireColorimetry(transfer: .pq, primaries: .rec2020))
        #expect(wide.primaries == .rec2020,
                "a Rec.2020 frame came out as \(wide.primaries)")
    }

    /// A neutral frame plots on the white point, in both gamuts — the cross an
    /// operator judges white balance against.
    @Test func aNeutralFrameLandsOnTheWhitePoint() throws {
        for primaries: SignalPrimaries in [.rec709, .rec2020] {
            let plotted: Chromaticity = peak(try analyzed(
                r: 500, g: 500, b: 500,
                colorimetry: WireColorimetry(transfer: .sdr,
                                             primaries: primaries)))
            #expect(abs(plotted.x - ColorPrimaries.d65.x) < 2 * Self.cell,
                    "\(primaries) neutral plotted at x \(plotted.x)")
            #expect(abs(plotted.y - ColorPrimaries.d65.y) < 2 * Self.cell,
                    "\(primaries) neutral plotted at y \(plotted.y)")
        }
    }

    // MARK: - what the map may never contain

    /// A channel BELOW nominal black is floored at zero rather than taken
    /// negative, so a frame whose green and blue ride into the footroom plots
    /// on the red primary exactly.
    ///
    /// This is the sharp version of the invariant below, and it is the reason
    /// the floor is in `HDRTransfer.sdrLinearLight` rather than left to the
    /// caller: a negative base under a fractional power is not a dark colour,
    /// it is NaN, and a NaN chromaticity is dropped silently — the samples an
    /// operator most needs to see would simply not be on the chart.
    @Test func aSubBlackChannelIsFlooredRatherThanTakenNegative() throws {
        let data: ScopeData = try analyzed(r: Self.white, g: 4, b: 4)
        let lit: Int = data.cie.filter { $0 > 0 }.count
        #expect(lit > 0,
                "nothing was plotted at all, which is what a NaN chromaticity looks like")
        let plotted: Chromaticity = peak(data)
        let corner: Chromaticity = ColorPrimaries.rec709.red
        #expect(abs(plotted.x - corner.x) < 2 * Self.cell,
                "footroom green and blue plotted at x \(plotted.x), corner \(corner.x)")
        #expect(abs(plotted.y - corner.y) < 2 * Self.cell,
                "footroom green and blue plotted at y \(plotted.y), corner \(corner.y)")
    }

    /// Every lit cell is inside the frame's own gamut triangle, sub-blacks and
    /// super-whites included — a colour more saturated than the camera's own
    /// primaries is not a thing a camera can send, so it is not a thing the
    /// chart may show.
    ///
    /// The slack is the map's own resolution rather than a fudge: the split
    /// deposit reaches a cell away from the true point, the separable blur one
    /// further, and a cell reports its own centre — two and a half cells in
    /// each axis, and the worst case is a corner, where that is 2.6 cells of
    /// perpendicular distance from both edges at once (measured).
    @Test func everyPlottedColourIsInsideTheFramesOwnGamut() throws {
        let frame: CVPixelBuffer = try R210Fixtures.make { x, y in
            // the whole code range, excursions and all
            R210Fixtures.Codes(r: 4 + (x * 1015) / 319,
                               g: 4 + (y * 1015) / 179,
                               b: 4 + ((x + y) * 1015) / 498)
        }
        let data: ScopeData = try #require(
            ScopeAnalyzer.analyze(frame, wireLevels: .limited),
            "the analyzer refused the gradient frame")
        let triangle: [Chromaticity] = ColorPrimaries.rec709.triangle
        var outside: [Chromaticity] = []
        for index: Int in data.cie.indices where data.cie[index] > 0 {
            let point: Chromaticity = chromaticity(ofCell: index)
            if !inside(point, triangle, slack: 3.5 * Self.cell) {
                outside.append(point)
            }
        }
        let worst: String = outside.isEmpty ? "none"
            : "\(outside[0].x), \(outside[0].y)"
        #expect(outside.isEmpty,
                "\(outside.count) cells sit outside the Rec.709 triangle, the first at \(worst)")
    }

    /// Whether a point is inside a triangle, allowing `slack` in xy units —
    /// the map's own cell size plus the blur that follows the deposit.
    private func inside(_ point: Chromaticity, _ triangle: [Chromaticity],
                        slack: Double) -> Bool {
        guard triangle.count == 3 else { return false }
        var signs: [Double] = []
        for index: Int in 0..<3 {
            let a: Chromaticity = triangle[index]
            let b: Chromaticity = triangle[(index + 1) % 3]
            let edgeX: Double = b.x - a.x, edgeY: Double = b.y - a.y
            let length: Double = (edgeX * edgeX + edgeY * edgeY).squareRoot()
            guard length > 0 else { return false }
            let cross: Double = edgeX * (point.y - a.y) - edgeY * (point.x - a.x)
            signs.append(cross / length)
        }
        return signs.allSatisfy { $0 >= -slack } || signs.allSatisfy { $0 <= slack }
    }

    // MARK: - the trace sits where it really is

    /// The chart shares the vectorscope's split deposit, and this is the
    /// property that says so.
    ///
    /// With a sample dropped WHOLE into the cell it falls in, the separable
    /// 1-2-1 that follows spreads it symmetrically — so the two neighbours of
    /// the peak hold the same value at every sub-cell position, and the trace
    /// can only ever report a cell centre. Split between the cells around it,
    /// the neighbours are unequal by exactly how far off centre the sample is.
    /// One code of green here moves the colour about a tenth of a cell, so
    /// every step of this sweep is a position the map has no cell for.
    @Test func theTraceCanSitBetweenCellsAndNotOnlyOnThem() throws {
        var asymmetric: [Int] = []
        for step: Int in 0...4 {
            let data: ScopeData = try analyzed(r: Self.white,
                                               g: Self.half + step * 3,
                                               b: Self.black)
            var best: Int = 0
            for index: Int in data.cie.indices
            where data.cie[index] > data.cie[best] {
                best = index
            }
            let size: Int = ScopeData.cieSize
            guard best % size > 0, best % size < size - 1 else { continue }
            if data.cie[best - 1] != data.cie[best + 1] { asymmetric.append(step) }
        }
        #expect(!asymmetric.isEmpty,
                "the peak was symmetric at every sub-cell position, so the map can only report cell centres")
    }
}
