import CaptureCore
import Testing

@testable import TakeShotKit

/// Where the colour-bar boxes sit is a fact about the matrix the signal is
/// coded in, not a constant.
///
/// docs/coverage.md and CLAUDE.md both carried this as a deliberate gap: "the
/// vectorscope graticule's targets are Rec.709, so a Rec.2020 bar chart will
/// not land on its boxes". Rec.2020 codes luma with different weights
/// (0.2627/0.6780/0.0593 against 0.2126/0.7152/0.0722), so the same bar has
/// different chroma — and a graticule fixed on one of them tells an operator
/// their chart is off when it is exactly right.
@MainActor
struct ModelVectorscopeGamutTests {
    private func distance(_ a: VectorscopeView.VectorTarget,
                          _ b: VectorscopeView.VectorTarget) -> Double {
        let dx = Double(a.x - b.x), dy = Double(a.y - b.y)
        return (dx * dx + dy * dy).squareRoot()
    }

    private func target(_ id: String,
                        _ primaries: SignalPrimaries)
        throws -> VectorscopeView.VectorTarget {
        try #require(VectorscopeView.targets75(primaries).first { $0.id == id },
                     "no target named \(id)")
    }

    /// The gap, stated as the measurement that closes it — and the measurement
    /// is what matters, because the size of the error decides whether this was
    /// worth fixing at all.
    ///
    /// Measured, in units of the scope's width: red moves 0.0188, and the
    /// smallest of the six moves 0.0042. A target BOX is 9 points, fixed, and
    /// the scope square is about 440 points in the window's two-up layout — so
    /// red's shift is about 8 points, which is nearly a whole box, and the
    /// smallest is about a fifth of one. That is the difference between an
    /// operator reading "this chart is off" and "this chart is right".
    @Test func theTargetsMoveWhenTheSignalChangesGamut() throws {
        var moved: [String: Double] = [:]
        for id in ["R", "G", "B", "Cy", "Mg", "Yl"] {
            moved[id] = distance(try target(id, .rec709),
                                 try target(id, .rec2020))
        }
        for (id, shift) in moved {
            #expect(shift > 0.004, "\(id) did not move at all: \(shift)")
        }
        let red = try #require(moved["R"])
        #expect(red > 0.018, "red moved only \(red) of the scope's width")
    }

    /// Rec.709 is untouched, to the last bit the printed constants gave.
    ///
    /// The weights are now DERIVED from the primaries rather than transcribed,
    /// which is what lets 2020 work at all — and the risk of deriving them is
    /// that 709 quietly moves too. The published coefficients round to the
    /// derived ones at four decimals, so a target may not move by more than a
    /// ten-thousandth of the scope.
    @Test func theRec709TargetsAreWhereTheyAlwaysWere() throws {
        // Computed from the printed 709 constants: Y = 0.2126R + 0.7152G +
        // 0.0722B, Cb = (B − Y)/1.8556, Cr = (R − Y)/1.5748, x = 0.5 + Cb/255.
        let printed: [String: (x: Double, y: Double)] = [
            "R": (0.5 + ((0 - 0.2126 * 191) / 1.8556) / 255,
                  0.5 - ((191 - 0.2126 * 191) / 1.5748) / 255),
            "B": (0.5 + ((191 - 0.0722 * 191) / 1.8556) / 255,
                  0.5 - ((0 - 0.0722 * 191) / 1.5748) / 255),
        ]
        for (id, want) in printed {
            let got = try target(id, .rec709)
            #expect(abs(Double(got.x) - want.x) < 1e-4,
                    "\(id) x moved to \(got.x) from \(want.x)")
            #expect(abs(Double(got.y) - want.y) < 1e-4,
                    "\(id) y moved to \(got.y) from \(want.y)")
        }
    }

    /// The property that makes the graticule worth anything: the box is where
    /// the analyzer will actually plot that bar. Both ends read one function,
    /// so this pins that they are told the SAME gamut — a graticule that moved
    /// while the trace stayed put would be a new way to be wrong.
    @Test func theBoxIsWhereTheAnalyzerPlotsThatBar() throws {
        for primaries in [SignalPrimaries.rec709, .rec2020] {
            let box = try target("Mg", primaries)
            let (cb, cr) = ScopeAnalyzer.chroma(r: 191, g: 0, b: 191,
                                                primaries: primaries)
            #expect(abs(Double(box.x) - (0.5 + cb / 255)) < 1e-12,
                    "\(primaries) x disagrees with the analyzer")
            #expect(abs(Double(box.y) - (0.5 - cr / 255)) < 1e-12,
                    "\(primaries) y disagrees with the analyzer")
        }
    }

    /// A neutral sample has no chroma under any matrix — the one point every
    /// gamut agrees on, and the reason a grey chart cannot reveal this bug.
    @Test func neutralIsAtTheCentreUnderEveryGamut() {
        for primaries in [SignalPrimaries.rec709, .rec2020] {
            let (cb, cr) = ScopeAnalyzer.chroma(r: 128, g: 128, b: 128,
                                                primaries: primaries)
            #expect(abs(cb) < 1e-12, "\(primaries) cb is \(cb)")
            #expect(abs(cr) < 1e-12, "\(primaries) cr is \(cr)")
        }
    }

    /// The denominators follow from the weights rather than sitting beside them
    /// as constants: 2(1 − Yb) and 2(1 − Yr). Pinned against the numbers the
    /// two standards print, because that is the claim.
    @Test func theDenominatorsAreTheOnesTheStandardsPrint() {
        let cases: [(SignalPrimaries, Double, Double)] = [
            (.rec709, 1.8556, 1.5748), (.rec2020, 1.8814, 1.4746),
        ]
        for (primaries, cb, cr) in cases {
            let w = primaries.rgbToXYZ.lumaWeights
            #expect(abs(2 * (1 - w.b) - cb) < 5e-4,
                    "\(primaries) Cb denominator is \(2 * (1 - w.b))")
            #expect(abs(2 * (1 - w.r) - cr) < 5e-4,
                    "\(primaries) Cr denominator is \(2 * (1 - w.r))")
        }
    }
}
