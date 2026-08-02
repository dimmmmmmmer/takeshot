import Foundation

/// What the source's code values mean on the wire, and therefore what the
/// levels stage does with them.
///
/// The setting has always been a string on `CaptureSettings.videoLevels`, and
/// it stays one so older saved JSON keeps decoding; this is the resolved form
/// the pipeline and `TenBitConverter` actually branch on, so the decision is
/// made once instead of by string comparison at four sites.
public enum InputLevels: String, Sendable, CaseIterable {
    /// Full swing: the codes already fill 0…1023 (0…255 in 8-bit) and nothing
    /// is done to them. A playout device set to Full output.
    case full
    /// Studio swing, expanded so the camera's WHOLE legal swing survives: the
    /// bottom of the 10-bit legal range (4) lands on 0 and the top (1019) on
    /// 1023, so no code the camera sent is destroyed.
    ///
    /// There used to be a second studio-swing mode that mapped nominal black
    /// (64) and nominal white (940) onto the ends instead. It is gone, and the
    /// stored value that named it (`limited_excursions`) now resolves here:
    /// that reading CLAMPED, so the sub-blacks a camera rides below picture
    /// black and the super-whites above reference white stopped existing — in
    /// the display buffer and, because the record buffer is built from the
    /// expanded value, in the deliverable as well. Reference white sits at
    /// 1017 of 1023 rather than at 1023 in exchange, which is a hair of
    /// contrast for a highlight the colourist still has.
    case limited

    /// The setting string as the pipeline resolved it for this frame. Anything
    /// unrecognised — `auto` once it has decided the source is studio swing,
    /// and the retired `limited_excursions` spelling — means `limited`, an
    /// HDMI camera's CTA-861 default.
    public static func resolved(_ setting: String?) -> InputLevels {
        InputLevels(rawValue: setting ?? "") ?? .limited
    }

    /// The 10-bit wire codes this mode maps onto 0 and 1023.
    public var wireWindow: (black: Int, white: Int) {
        switch self {
        case .full: return (0, 1023)
        // 4…1019 is the legal 10-bit code range: 0-3 and 1020-1023 are
        // reserved for sync words and never carry picture.
        case .limited: return (4, 1019)
        }
    }

    /// Whether the 8-bit path has to expand at all.
    public var expandsEightBit: Bool { self != .full }

    /// The 8-bit expansion window, the same decision in the units the vImage
    /// table works in. 1…254 rather than 4…1019/4: 0 and 255 are the 8-bit
    /// reserved codes.
    public var eightBitWindow: (black: Int, white: Int) {
        switch self {
        case .full: return (0, 255)
        case .limited: return (1, 254)
        }
    }
}
