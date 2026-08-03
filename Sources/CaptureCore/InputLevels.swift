import Foundation

/// What the source's code values mean on the wire, and therefore what the
/// levels stage does with them.
///
/// The setting has always been a string on `CaptureSettings.videoLevels`, and
/// it stays one so older saved JSON keeps decoding; this is the resolved form
/// the pipeline and `TenBitConverter` actually branch on, so the decision is
/// made once instead of by string comparison at four sites.
///
/// One decision, but it reaches three products that need different things from
/// it, and this type only answers for the first:
///
/// - the PICTURE (here) — nominal black lands on 0 and nominal white on 1023,
///   because an operator judges exposure against a black that is black;
/// - the FILE (`TenBitConverter.precomp`) — the camera's codes as sent,
///   footroom and headroom included, so nothing is destroyed in the
///   deliverable;
/// - the SCOPES (`ScopeWireLevels`) — the wire, unexpanded, with the
///   excursions drawn outside the nominal lines where they can be seen.
public enum InputLevels: String, Sendable, CaseIterable {
    /// Full swing: the codes already fill 0…1023 (0…255 in 8-bit) and nothing
    /// is done to them. A playout device set to Full output.
    case full
    /// Studio swing, expanded to the display's full scale on the NOMINAL pair:
    /// black 64 onto 0, white 940 onto 1023.
    ///
    /// The excursions a camera legally rides outside that pair — footroom down
    /// to code 4, headroom up to 1019 — are clipped in the picture, and that is
    /// the point rather than an oversight: expanding the whole legal swing
    /// 4…1019 instead put nominal black at 60 of 1023, so every black on the
    /// monitor sat 6 % up the scale and the operator was judging exposure
    /// against a grey. Nothing is lost by clipping HERE: the excursions are in
    /// the recorded file (the record buffer carries the wire codes, not this
    /// expansion) and on the scopes (they read the wire).
    ///
    /// There used to be a second studio-swing mode; the stored value that named
    /// it (`limited_excursions`) resolves here.
    case limited

    /// The setting string as the pipeline resolved it for this frame. Anything
    /// unrecognised — `auto` once it has decided the source is studio swing,
    /// and the retired `limited_excursions` spelling — means `limited`, an
    /// HDMI camera's CTA-861 default.
    public static func resolved(_ setting: String?) -> InputLevels {
        InputLevels(rawValue: setting ?? "") ?? .limited
    }

    /// The 10-bit wire codes this mode maps onto 0 and 1023 IN THE DISPLAY
    /// BUFFER — the preview, the LUT stage, the playout mirror, the multiview.
    ///
    /// Nominal (64/940), not legal (4/1019): see the case above. The recorded
    /// file does not come through here at all — `TenBitConverter` builds it
    /// from the wire code — so widening this window can no longer put a stretch
    /// into a deliverable, and narrowing it can no longer take a code out of
    /// one.
    public var wireWindow: (black: Int, white: Int) {
        switch self {
        case .full: return (0, 1023)
        case .limited: return (64, 940)
        }
    }

    /// Whether the 8-bit path has to expand at all.
    public var expandsEightBit: Bool { self != .full }

    /// The display window again, in the units the 8-bit vImage table works in:
    /// nominal black 16 onto 0 and nominal white 235 onto 255.
    public var eightBitWindow: (black: Int, white: Int) {
        switch self {
        case .full: return (0, 255)
        case .limited: return (16, 235)
        }
    }
}
