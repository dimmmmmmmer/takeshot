import Foundation

/// YCbCr wire codes → R'G'B' wire codes, with the SWING left alone.
///
/// This is the one piece of colorimetry a YCbCr wire format needs that an RGB
/// one does not, and it is deliberately NOT a levels stage. The distinction is
/// what lets the 10-bit YCbCr path join the wire-converter family instead of
/// forking it:
///
/// - the MATRIX (here) changes colour space and nothing else. A studio-swing
///   YCbCr frame comes out as studio-swing R'G'B' codes — nominal black still
///   64, nominal white still 940 — which is exactly the domain an `'r210'` wire
///   frame is already in;
/// - the LEVELS decision then happens where it happens for every other format,
///   in `WireDisplayTable`, on those R'G'B' codes. So a 10-bit YCbCr source and
///   a 10-bit RGB source reach the monitor through the same table, and the
///   project's rule that two depths cannot drift into showing different blacks
///   extends to two colour SPACES for free.
///
/// The usual textbook conversion folds the two together (the "video range to
/// full range" YCbCr matrix, `1.164·(Y−64) + 1.793·(Cr−512)` and friends).
/// Folding them is what would have forced a second display policy: the levels
/// mode would have been baked into the matrix, and the one table the operator's
/// blacks depend on would have had a YCbCr-shaped hole in it.
///
/// ## The numbers
///
/// BT.709 luma is `Y' = 0.2126 R' + 0.7152 G' + 0.0722 B'`, and the colour
/// differences are `Cb = (B' − Y')/1.8556` and `Cr = (R' − Y')/1.5748` — the
/// same constants `ScopeAnalyzer.chroma` uses to position the vectorscope
/// graticule, so a bar lands on its box whichever wire format it arrived on.
/// Inverted:
///
///     R' = Y' + 1.5748·Cr
///     G' = Y' − 0.187324·Cb − 0.468124·Cr
///     B' = Y' + 1.8556·Cb
///
/// Those are normalized values. The one thing that has to be corrected when
/// working in CODES is that studio swing does not code luma and chroma over the
/// same number of counts: luma gets 876 (64…940) and each chroma channel gets
/// 896 (64…960, zero at 512). A colour difference of one luma count is therefore
/// 896/876 chroma counts, and `gain` is that ratio — the whole difference
/// between the two modes.
///
/// A neutral pixel (both chroma channels at 512) comes out `R = G = B = Y`
/// EXACTLY, at every code and in both modes: the offsets are zero and nothing is
/// scaled. That is not a coincidence to be grateful for, it is the property the
/// three-way display-agreement test rests on. It holds for BOTH sets of
/// primaries below, which is what lets a Rec.2020 signal join the same display
/// table as everything else.
///
/// ## The second set of coefficients
///
/// BT.2100 requires Rec.2020 primaries of a PQ or HLG signal, and non-constant
/// -luminance Rec.2020 codes luma with different weights: 0.2627 / 0.6780 /
/// 0.0593 rather than 709's 0.2126 / 0.7152 / 0.0722. Matrixing a 2020 signal
/// with 709's coefficients is not a rounding difference — it is a hue error
/// that grows with saturation, and it would be invisible on a grey chart and
/// obvious on a face. So the matrix is chosen by the signal's primaries, and
/// `rec709` remains what every existing caller gets by default.
struct WireYCbCr: Sendable {
    /// The code both chroma channels sit on when there is no colour.
    static let chromaZero = 512
    /// The top of the 10-bit wire scale this type works on.
    static let maxCode = 1023
    /// Fixed point for the four coefficients: 12 fractional bits, which keeps
    /// every coefficient exact to better than 0.0002 and leaves a 10-bit code
    /// times a coefficient far inside `Int`.
    private static let fractionBits = 12

    private let crToRed: Int
    private let cbToGreen: Int
    private let crToGreen: Int
    private let cbToBlue: Int
    /// How much a raw chroma DIFFERENCE has to be scaled to be measured in luma
    /// counts. Needed outside the matrix as well — the scopes hand the
    /// accumulator a colour difference and it applies its own gain on top.
    let chromaGain: Double

    /// The four inverse-matrix coefficients for one set of primaries, before
    /// the swing gain. Named rather than four bare Doubles: they are all
    /// multipliers of a chroma difference and swapping two of them silently
    /// produces a plausible-looking wrong picture.
    private struct Coefficients {
        let crToRed: Double
        let cbToGreen: Double
        let crToGreen: Double
        let cbToBlue: Double

        /// BT.709: Kr 0.2126, Kg 0.7152, Kb 0.0722.
        static let rec709 = Coefficients(
            crToRed: 1.5748, cbToGreen: -0.187324,
            crToGreen: -0.468124, cbToBlue: 1.8556)
        /// BT.2020 non-constant luminance: Kr 0.2627, Kg 0.6780, Kb 0.0593,
        /// so Cb spans 2(1−Kb) = 1.8814 and Cr spans 2(1−Kr) = 1.4746, and the
        /// green terms are −(Kb/Kg)·1.8814 and −(Kr/Kg)·1.4746.
        static let rec2020 = Coefficients(
            crToRed: 1.4746, cbToGreen: -0.164553,
            crToGreen: -0.571353, cbToBlue: 1.8814)

        static func forPrimaries(_ primaries: SignalPrimaries) -> Coefficients {
            primaries == .rec2020 ? .rec2020 : .rec709
        }
    }

    /// `studioSwing` states what the SOURCE carries, exactly as `InputLevels`
    /// does: true for the 64…940 / 64…960 coding SDI and HDMI YCbCr always use,
    /// false for a playout device set to Full output.
    init(studioSwing: Bool, primaries: SignalPrimaries = .rec709) {
        let gain = studioSwing ? 876.0 / 896.0 : 1.0
        let coefficients = Coefficients.forPrimaries(primaries)
        func fixed(_ coefficient: Double) -> Int {
            Int((coefficient * gain * Double(1 << Self.fractionBits)).rounded())
        }
        crToRed = fixed(coefficients.crToRed)
        cbToGreen = fixed(coefficients.cbToGreen)
        crToGreen = fixed(coefficients.crToGreen)
        cbToBlue = fixed(coefficients.cbToBlue)
        chromaGain = gain
    }

    /// The matrix for a resolved input-levels mode — the capture path's spelling
    /// of the same question.
    init(levels: InputLevels, primaries: SignalPrimaries = .rec709) {
        self.init(studioSwing: levels != .full, primaries: primaries)
    }

    /// …and the scopes' spelling of it.
    init(levels: ScopeWireLevels, primaries: SignalPrimaries = .rec709) {
        self.init(studioSwing: levels != .full, primaries: primaries)
    }

    /// One pixel's R'G'B' on the wire's own scale, clamped into it.
    ///
    /// The clamp is the RGB gamut, and it is unavoidable rather than a policy:
    /// a YCbCr triple can name a colour no R'G'B' triple can hold, and every
    /// consumer of this — the display buffer and the scopes' RGB parade — is
    /// R'G'B'. The scopes keep the unclamped wire chroma and luma alongside (see
    /// `chromaDifference`), so an illegal excursion is still plotted as itself
    /// on the vectorscope and the luma trace.
    struct RGB: Equatable {
        let r: Int
        let g: Int
        let b: Int
    }

    @inline(__always)
    func rgb(luma: Int, cb: Int, cr: Int) -> RGB {
        let blueDifference = cb - Self.chromaZero
        let redDifference = cr - Self.chromaZero
        return RGB(
            r: Self.clamped(luma + Self.rounded(crToRed * redDifference)),
            g: Self.clamped(luma + Self.rounded(cbToGreen * blueDifference
                    + crToGreen * redDifference)),
            b: Self.clamped(luma + Self.rounded(cbToBlue * blueDifference)))
    }

    /// The chroma of a wire sample as a colour DIFFERENCE measured in luma
    /// counts — what the scope accumulator wants, because its own `chromaGain`
    /// then puts it on the full-range scale the graticule targets sit on.
    /// Unclamped on purpose: this is the path an illegal chroma excursion
    /// survives on.
    @inline(__always)
    func chromaDifference(cb: Int, cr: Int) -> (cb: Double, cr: Double) {
        (Double(cb - Self.chromaZero) * chromaGain,
         Double(cr - Self.chromaZero) * chromaGain)
    }

    /// Fixed point back to a code, rounded half up. An arithmetic shift right is
    /// a floor, so adding half first rounds rather than biasing every negative
    /// offset one code down.
    @inline(__always)
    private static func rounded(_ value: Int) -> Int {
        (value + (1 << (fractionBits - 1))) >> fractionBits
    }

    @inline(__always)
    private static func clamped(_ code: Int) -> Int {
        min(maxCode, max(0, code))
    }
}
