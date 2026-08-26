import CoreVideo
import Foundation
import Testing

@testable import CaptureCore

/// The luma trace and the Y histogram are drawn with the coefficients of the
/// matrix the signal is coded in.
///
/// Rec.2020 codes luma with different weights than Rec.709 — 0.2627/0.6780/
/// 0.0593 against 0.2126/0.7152/0.0722 — so a waveform drawn with 709's on a
/// 2020 signal reads a saturated green too dark and a saturated blue too
/// bright. That is an exposure judgement made against the wrong number, which
/// is the one thing this instrument exists to get right.
///
/// Only the RGB path has a choice to make: a YCbCr wire frame carries the luma
/// the camera coded with its own matrix, and the analyzer plots that.
struct ScopeLumaGamutTests {
    /// A uniform RGB frame at the given 8-bit triple, as an r210 wire frame.
    private func analyzed(r: Int, g: Int, b: Int,
                          primaries: SignalPrimaries) throws -> ScopeData {
        let frame = try R210Fixtures.make(width: 128, height: 72) { _, _ in
            R210Fixtures.Codes(r: r << 2, g: g << 2, b: b << 2)
        }
        return try #require(
            ScopeAnalyzer.analyze(frame, wireLevels: .full,
                                  colorimetry: WireColorimetry(
                                    transfer: .sdr, primaries: primaries)),
            "the analyzer refused an 'r210' frame")
    }

    /// The peak bin of the luma histogram, in 10-bit codes.
    private func lumaPeak(_ data: ScopeData) throws -> Int {
        let peak = try #require(data.histY.firstIndex(of: data.histY.max() ?? 0))
        return peak * 4
    }

    /// Saturated green is where the two standards disagree most: 0.7152
    /// against 0.6780 of full scale, which is 9.5 codes of 1023 — a visible
    /// step on a waveform an operator is reading a stop off.
    @Test func saturatedGreenReadsDifferentlyUnderTheTwoGamuts() throws {
        let seven = try lumaPeak(try analyzed(r: 0, g: 255, b: 0,
                                              primaries: .rec709))
        let twenty = try lumaPeak(try analyzed(r: 0, g: 255, b: 0,
                                               primaries: .rec2020))
        #expect(seven > twenty,
                "2020 weights green lower: 709 \(seven), 2020 \(twenty)")
        #expect(seven - twenty >= 8,
                "the two gamuts differ by only \(seven - twenty) codes")
    }

    /// And blue the other way, so the difference is a MATRIX and not a gain —
    /// a single scale factor applied to every channel would move both the same
    /// direction and this pair is what rules that out.
    @Test func saturatedBlueReadsTheOtherWayRound() throws {
        let seven = try lumaPeak(try analyzed(r: 0, g: 0, b: 255,
                                              primaries: .rec709))
        let twenty = try lumaPeak(try analyzed(r: 0, g: 0, b: 255,
                                               primaries: .rec2020))
        #expect(seven > twenty,
                "709 weights blue higher: 709 \(seven), 2020 \(twenty)")
    }

    /// Rec.709 is where it always was. The weights are DERIVED now rather than
    /// transcribed, and the risk of deriving them is that the default quietly
    /// moves: 255 of green through the printed 0.7152 is 182.4 in 8-bit, 729.7
    /// in 10-bit, and the histogram bins are 4 codes wide.
    @Test func theRec709ReadingIsWhereItAlwaysWas() throws {
        let green = try lumaPeak(try analyzed(r: 0, g: 255, b: 0,
                                              primaries: .rec709))
        let printed = Int((0.7152 * 1020).rounded())
        #expect(abs(green - printed) <= 4,
                "709 green reads \(green), the printed weights give \(printed)")
    }

    /// A neutral frame is the one reading every matrix agrees on, which is why
    /// a grey chart cannot reveal any of this.
    @Test func neutralReadsTheSameUnderEveryGamut() throws {
        let seven = try lumaPeak(try analyzed(r: 128, g: 128, b: 128,
                                              primaries: .rec709))
        let twenty = try lumaPeak(try analyzed(r: 128, g: 128, b: 128,
                                               primaries: .rec2020))
        #expect(seven == twenty,
                "neutral moved between gamuts: \(seven) then \(twenty)")
    }
}
