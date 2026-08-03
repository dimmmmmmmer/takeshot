import Foundation

/// The transfer characteristic the SOURCE is encoding with — the one thing an
/// HDR signal says about itself that an SDR one never had to.
///
/// It is deliberately NOT a levels mode and NOT a colour space. Those two
/// questions already have answers in this pipeline (`InputLevels` and
/// `WireYCbCr`), and folding a third into either of them is how one signal
/// property ends up deciding another's behaviour. What a transfer decides, and
/// all it decides, is what a code value MEANS as a luminance.
///
/// - `sdr` is everything that shipped before HDR existed here, and it is the
///   value every path takes when the signal says nothing or the operator turns
///   HDR handling off. On `sdr` every table, tag and scale in the app is
///   byte-identical to what it was — that is a requirement, not an aspiration,
///   and `WireDisplayTable.table` states it in one line.
/// - `pq` is SMPTE ST 2084: ABSOLUTE, so a code names a luminance in cd/m²
///   directly, 0…10000.
/// - `hlg` is ARIB STD-B67 / ITU-R BT.2100: RELATIVE and scene-referred, so a
///   code names a luminance only once a reference display is named with it.
///   This app names BT.2100's, 1000 cd/m² — see `HDRTransfer.hlgPeakNits`.
public enum SignalTransfer: String, Sendable, CaseIterable {
    case sdr
    case pq
    case hlg

    /// Whether anything in the app has to behave differently at all.
    public var isHDR: Bool { self != .sdr }

    /// A signal the board reported, as a setting-shaped string would spell it.
    /// Unknown spellings mean `sdr`, which is the safe direction: an
    /// unrecognised signal keeps today's behaviour rather than being tone
    /// mapped on a guess.
    public static func resolved(_ raw: String?) -> SignalTransfer {
        SignalTransfer(rawValue: raw ?? "") ?? .sdr
    }
}

/// The HDR transfer curves, and the single display transform built on them.
///
/// ## What the transform is for
///
/// A video-assist viewer's job is to let an operator judge exposure, and the
/// app's whole display half is an 8-bit BGRA buffer that reaches the preview,
/// the LUT stage, the scopes' fallback, the still grabs, the hardware playout
/// mirror and the phone multiview. Driving an EDR display would mean a
/// half-float chain for every one of those, and the two surfaces that matter
/// most on a set — the SDI/HDMI playout and the director's cheap monitor — are
/// not EDR displays at all and never will be. So an HDR signal is TONE MAPPED
/// into the existing SDR display path, and it joins that path where every other
/// levels decision is already made: as a different `WireDisplayTable`. The
/// per-frame cost is therefore exactly zero — the converters were already doing
/// one table lookup per component and they still do one.
///
/// ## The transform, stated
///
/// 1. **Linearize to absolute display luminance, cd/m².** PQ is absolute by
///    construction. HLG is scene-referred, so the BT.2100 OOTF (system gamma
///    1.2 at the 1000 cd/m² reference display) is applied — without it PQ and
///    HLG would disagree about the same picture, which is the one thing
///    BT.2100 exists to prevent. Measured both ways: HLG signal 0.75 comes out
///    at 203.2 cd/m² and HLG 0.38 at 26.3, which are BT.2408's HDR Reference
///    White and HDR Reference Level to three figures.
/// 2. **Normalize by BT.2408's HDR Reference White, 203 cd/m².** This is the
///    anchor that makes the operator's exposure judgement transfer: an 18 %
///    grey card graded to BT.2408 sits at 26 cd/m², i.e. 0.128 of reference
///    white, and 0.128 through the encode below lands on 42.5 % of the display
///    scale — where an 18 % card sits on an SDR monitor (40.9 % through the
///    Rec.709 OETF). Within two points of the scale, and pinned.
/// 3. **Shoulder the highlights.** Below the knee there is NO compression at
///    all: shadow, mid-grey, skin and everything up to within half a stop of
///    diffuse white is an exact transfer conversion and nothing else. Above it
///    a C¹ rational shoulder asymptotes to the top of the scale, so a specular
///    keeps its shape instead of becoming a flat white patch.
/// 4. **Encode with BT.1886, gamma 2.4.** The chain is display-referred from
///    step 1 onward, so the inverse of the SDR DISPLAY EOTF is what puts a
///    luminance back on a code. Choosing it rather than the Rec.709 camera OETF
///    is what makes step 2's agreement come out; it is also the one constant
///    here that only a real display can confirm.
///
/// ## What it deliberately does not do
///
/// It does not convert PRIMARIES. A Rec.2020 signal's display buffer is tagged
/// with Rec.2020 primaries and a Rec.709 transfer, and ColorSync converts it to
/// the display profile — the same route every SDR frame already takes, at no
/// per-pixel cost. A 3×3 gamut matrix in linear light per pixel would be real
/// per-frame work for a result the compositor already gives away.
///
/// It is also PER CHANNEL, like every transfer function. Below the knee that is
/// exactly right. Above it, a shoulder applied per channel desaturates
/// highlights toward white — the standard behaviour of a simple tone map, and
/// the right behaviour for an instrument: a clipped channel should read as
/// clipped rather than being hue-corrected into looking healthy.
public enum HDRTransfer {
    // MARK: - the anchors

    /// ITU-R BT.2408 HDR Reference White: the luminance diffuse white is graded
    /// to under both PQ and HLG, and therefore the luminance this app maps onto
    /// the top of the SDR display scale.
    public static let referenceWhiteNits = 203.0
    /// BT.2408 HDR Reference Level — an 18 % grey card. The transform does not
    /// use it; the tests do, because "a grey card reads the same whether the
    /// camera is in Rec.709 or in PQ" is the property that makes an HDR picture
    /// judgeable on an SDR monitor at all.
    public static let referenceGreyNits = 26.0
    /// The top of the PQ scale.
    public static let pqPeakNits = 10000.0
    /// The nominal peak of the BT.2100 HLG reference display, and therefore the
    /// luminance HLG signal 1.0 stands for. HLG carries no absolute luminance
    /// of its own, so every nits number this app prints for an HLG source is
    /// "at the BT.2100 reference display" and says so.
    public static let hlgPeakNits = 1000.0
    /// BT.2100 HLG system gamma at that reference display.
    static let hlgSystemGamma = 1.2
    /// BT.1886 display gamma — the SDR display EOTF the encode inverts.
    static let displayGamma = 2.4
    /// Where the highlight shoulder starts, as a fraction of reference white.
    /// 0.75 is 0.41 stop below diffuse white: every tone an operator judges
    /// exposure by is below it and therefore uncompressed.
    static let shoulderKnee = 0.75

    // MARK: - SMPTE ST 2084 (PQ)

    private static let m1 = 2610.0 / 16384
    private static let m2 = 2523.0 / 4096 * 128
    private static let c1 = 3424.0 / 4096
    private static let c2 = 2413.0 / 4096 * 32
    private static let c3 = 2392.0 / 4096 * 32

    /// PQ signal (0…1) → absolute display luminance, cd/m².
    ///
    /// The signal is CLAMPED into 0…1 rather than extrapolated, and that is the
    /// same rule the SDR display table already follows: a wire code outside the
    /// nominal pair is an excursion, it clips against the ends of the picture,
    /// and it survives in the file and on the scopes, which read the wire.
    static func pqNits(_ signal: Double) -> Double {
        let e = min(1, max(0, signal))
        let t = pow(e, 1 / m2)
        let denominator = c2 - c3 * t
        guard denominator > 0 else { return pqPeakNits }
        return pqPeakNits * pow(max(t - c1, 0) / denominator, 1 / m1)
    }

    /// cd/m² → PQ signal. Exact inverse of `pqNits` inside the scale.
    static func pqSignal(_ nits: Double) -> Double {
        let y = pow(min(pqPeakNits, max(0, nits)) / pqPeakNits, m1)
        return pow((c1 + c2 * y) / (1 + c3 * y), m2)
    }

    // MARK: - ARIB STD-B67 (HLG)

    private static let hlgA = 0.17883277
    private static let hlgB = 0.28466892
    private static let hlgC = 0.55991073
    /// The signal level BT.2408 puts diffuse white on.
    public static let hlgReferenceWhiteSignal = 0.75

    /// HLG signal (0…1) → SCENE linear (0…1). The inverse OETF.
    static func hlgScene(_ signal: Double) -> Double {
        let e = min(1, max(0, signal))
        guard e > 0.5 else { return e * e / 3 }
        return (exp((e - hlgC) / hlgA) + hlgB) / 12
    }

    /// Scene linear → HLG signal. The OETF.
    static func hlgSignal(_ scene: Double) -> Double {
        let e = min(1, max(0, scene))
        guard e > 1.0 / 12 else { return (3 * e).squareRoot() }
        return hlgA * log(12 * e - hlgB) + hlgC
    }

    /// HLG signal → absolute luminance on the BT.2100 reference display.
    ///
    /// The OOTF is what makes an HLG picture and a PQ picture of the same scene
    /// come out the same here: applying it puts HLG's diffuse white (signal
    /// 0.75) on 203 cd/m² and its grey (0.38) on 26, which are exactly PQ's
    /// two reference levels. Skipping it — feeding the HLG signal to an SDR
    /// display as-is, the "HLG is backwards compatible" claim — puts diffuse
    /// white at 75 % of the scale, about a stop and a half dark, which is not
    /// something an operator can judge exposure against.
    static func hlgNits(_ signal: Double) -> Double {
        hlgPeakNits * pow(hlgScene(signal), hlgSystemGamma)
    }

    /// The inverse of `hlgNits`.
    static func hlgSignal(forNits nits: Double) -> Double {
        let scene = pow(min(hlgPeakNits, max(0, nits)) / hlgPeakNits,
                        1 / hlgSystemGamma)
        return hlgSignal(scene)
    }

    // MARK: - the display transform

    /// Absolute luminance → the SDR display signal (0…1) it is shown at.
    public static func displaySignal(forNits nits: Double) -> Double {
        pow(min(1, shouldered(max(0, nits) / referenceWhiteNits)),
            1 / displayGamma)
    }

    /// The luminance a display level stands for — the exact inverse, and what
    /// the exposure aids are labelled through: a zebra set at a display level
    /// fires at THIS many cd/m² on the wire, and saying so is the difference
    /// between an assist that still means something under PQ and one that
    /// silently means something else.
    public static func nits(forDisplaySignal display: Double) -> Double {
        unshouldered(pow(min(1, max(0, display)), displayGamma))
            * referenceWhiteNits
    }

    /// The highlight shoulder, in units of reference white.
    ///
    /// Identity below the knee; above it a rational curve that meets the
    /// identity with a matching slope (C¹, so there is no visible break where
    /// it starts) and asymptotes to 1. It never reaches 1, which is the point:
    /// nothing an HDR camera can send comes out as flat clipped white, so a
    /// specular still has shape on the monitor and the operator can see WHERE
    /// the clip is instead of only that there is one.
    static func shouldered(_ x: Double) -> Double {
        let k = shoulderKnee
        guard x > k else { return x }
        return 1 - (1 - k) * (1 - k) / (x - 2 * k + 1)
    }

    /// The inverse of `shouldered`. 1 has no finite preimage (the curve only
    /// approaches it), so the top of the scale answers with the peak of the
    /// widest scale there is rather than infinity — a number a label can print.
    static func unshouldered(_ y: Double) -> Double {
        let k = shoulderKnee
        guard y > k else { return y }
        guard y < 1 else { return pqPeakNits / referenceWhiteNits }
        return (1 - k) * (1 - k) / (1 - y) + 2 * k - 1
    }
}

public extension SignalTransfer {
    /// Absolute display luminance for a normalized wire signal, cd/m².
    /// nil for `sdr`, where the question has no answer: an SDR code says how
    /// bright a pixel is RELATIVE to white and nothing about cd/m².
    func nits(forSignal signal: Double) -> Double? {
        switch self {
        case .sdr: return nil
        case .pq: return HDRTransfer.pqNits(signal)
        case .hlg: return HDRTransfer.hlgNits(signal)
        }
    }

    /// The inverse — where a luminance sits on this transfer's 0…1 signal.
    func signal(forNits nits: Double) -> Double? {
        switch self {
        case .sdr: return nil
        case .pq: return HDRTransfer.pqSignal(nits)
        case .hlg: return HDRTransfer.hlgSignal(forNits: nits)
        }
    }

    /// The top of this transfer's luminance scale, cd/m². nil for `sdr`.
    var peakNits: Double? {
        switch self {
        case .sdr: return nil
        case .pq: return HDRTransfer.pqPeakNits
        case .hlg: return HDRTransfer.hlgPeakNits
        }
    }

    /// The SDR display signal a wire signal is shown at. The IDENTITY for
    /// `sdr` — stated here once so that "HDR changes nothing for an SDR
    /// signal" is a property of one function rather than of every caller.
    func displaySignal(forSignal signal: Double) -> Double {
        guard let nits = nits(forSignal: signal) else { return signal }
        return HDRTransfer.displaySignal(forNits: nits)
    }

    /// What a level on the DISPLAY means as a luminance, for the exposure
    /// aids. nil for `sdr`, where a display level is already the answer.
    func nits(forDisplaySignal display: Double) -> Double? {
        guard isHDR else { return nil }
        return HDRTransfer.nits(forDisplaySignal: display)
    }
}
