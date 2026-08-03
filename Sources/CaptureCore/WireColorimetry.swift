import Foundation

/// What the app does with a signal that reports PQ or HLG.
///
/// Two cases and not three. There is no "force HDR": a transfer function is not
/// something an operator can be right about against the wire, and a Rec.709
/// signal tone mapped as if it were PQ is a picture a hundred times too dark —
/// the exact class of silent colour decision this project does not make. What
/// the operator CAN be right about is that the flag is wrong, and `off` is the
/// answer to that: the whole app behaves as it did before HDR existed.
public enum HDRMode: String, Sendable, CaseIterable, Identifiable {
    /// Follow the signal. The default, and a no-op on every SDR source.
    case auto
    /// Treat every source as SDR — today's behaviour, exactly.
    case off

    public var id: String { rawValue }

    /// The stored setting as the pipeline resolves it. Anything unrecognised
    /// means `auto`, so a settings file from a build that did not have this
    /// field behaves the way the feature is meant to be used.
    public static func resolved(_ setting: String?) -> HDRMode {
        HDRMode(rawValue: setting ?? "") ?? .auto
    }

    /// The colorimetry to act on, given what the signal reported.
    public func applied(to reported: WireColorimetry) -> WireColorimetry {
        self == .off ? .sdr : reported
    }
}

/// The colour primaries the source is encoding against.
///
/// Only the two that reach this app: Rec.709, which every SDR signal on a set
/// carries, and Rec.2020, which is what BT.2100 requires of a PQ or HLG one.
/// P3 is deliberately absent — no capture format the board delivers states it,
/// and a case nothing can produce is a case nobody can test.
public enum SignalPrimaries: String, Sendable, CaseIterable {
    case rec709
    case rec2020
}

/// CTA-861.3 static HDR metadata, as the board reports it.
///
/// Carried, written into the file, and shown in diagnostics — never used to
/// build a display curve. That is a decision rather than an omission: an
/// operator's reference has to be STABLE, and a picture whose contrast changes
/// because a camera re-sent its mastering metadata mid-shot is not a reference.
/// The display transform is fixed (see `HDRTransfer`); this is what post needs
/// in order to finish the job the same way the DP started it.
public struct HDRStaticMetadata: Equatable, Sendable {
    /// MaxCLL — the brightest pixel in the content, cd/m².
    public var maxContentLightLevel: Double
    /// MaxFALL — the brightest frame average, cd/m².
    public var maxFrameAverageLightLevel: Double
    /// The mastering display's luminance range, cd/m².
    public var maxDisplayLuminance: Double
    public var minDisplayLuminance: Double
    /// The mastering display's primaries and white point, CIE xy. Eight
    /// numbers that only travel together, so they are one value.
    public var displayPrimaries: Chromaticities?

    /// Red, green, blue and white in CIE xy — the `mdcv` box's whole payload.
    public struct Chromaticities: Equatable, Sendable {
        public var redX: Double
        public var redY: Double
        public var greenX: Double
        public var greenY: Double
        public var blueX: Double
        public var blueY: Double
        public var whiteX: Double
        public var whiteY: Double

        public init(redX: Double, redY: Double, greenX: Double, greenY: Double,
                    blueX: Double, blueY: Double,
                    whiteX: Double, whiteY: Double) {
            self.redX = redX
            self.redY = redY
            self.greenX = greenX
            self.greenY = greenY
            self.blueX = blueX
            self.blueY = blueY
            self.whiteX = whiteX
            self.whiteY = whiteY
        }
    }

    public init(maxContentLightLevel: Double = 0,
                maxFrameAverageLightLevel: Double = 0,
                maxDisplayLuminance: Double = 0,
                minDisplayLuminance: Double = 0,
                displayPrimaries: Chromaticities? = nil) {
        self.maxContentLightLevel = maxContentLightLevel
        self.maxFrameAverageLightLevel = maxFrameAverageLightLevel
        self.maxDisplayLuminance = maxDisplayLuminance
        self.minDisplayLuminance = minDisplayLuminance
        self.displayPrimaries = displayPrimaries
    }

    /// Whether anything here is worth writing into a file. A board that
    /// reports the interface but no values hands back zeros, and a `clli` box
    /// full of zeros tells post less than no box at all.
    public var isEmpty: Bool {
        maxContentLightLevel <= 0 && maxFrameAverageLightLevel <= 0
            && maxDisplayLuminance <= 0 && displayPrimaries == nil
    }
}

/// Everything the signal says about what its code values MEAN, gathered into
/// one value because the three answers only ever travel together.
///
/// The levels question — what RANGE the codes occupy — is deliberately not
/// here. That one is `InputLevels`, it is resolved separately, and an HDR
/// signal answers it exactly as an SDR one does: PQ and HLG over SDI and HDMI
/// are narrow-range coded like everything else, so the nominal pair is still
/// 64/940 in 10-bit units and the wire record path is untouched.
public struct WireColorimetry: Equatable, Sendable {
    public var transfer: SignalTransfer
    public var primaries: SignalPrimaries
    /// Static HDR metadata, when the board reported any.
    public var displayMetadata: HDRStaticMetadata?

    /// What every path assumes until something says otherwise, and what the
    /// app behaves as when the operator turns HDR handling off.
    public static let sdr = WireColorimetry(transfer: .sdr, primaries: .rec709)

    public init(transfer: SignalTransfer = .sdr,
                primaries: SignalPrimaries = .rec709,
                displayMetadata: HDRStaticMetadata? = nil) {
        self.transfer = transfer
        self.primaries = primaries
        self.displayMetadata = displayMetadata
    }

    public var isHDR: Bool { transfer.isHDR }

    /// The `ColorTags` preset the recorded FILE is tagged with, or nil when the
    /// operator's own colorimetry preset stands.
    ///
    /// An HDR take overrides the setting rather than being blended with it, and
    /// that is the point: the file has to state the transfer function the
    /// camera actually sent or every tool downstream guesses, and a guess about
    /// PQ is a picture that comes back a hundred times too dark or too bright.
    public var filePreset: String? {
        switch transfer {
        case .sdr: return nil
        case .pq: return ColorTags.pqPreset
        case .hlg: return ColorTags.hlgPreset
        }
    }

    /// The preset the DISPLAY buffer is tagged with, or nil for the operator's.
    ///
    /// Not the same answer as `filePreset`, and the asymmetry is the whole
    /// design: the file carries the WIRE codes and must say PQ, while the
    /// display buffer carries codes this app tone mapped into an SDR transfer
    /// and must say so — otherwise ColorSync would apply the PQ curve to
    /// something that is no longer PQ. What the two DO share is the primaries,
    /// because tone mapping is per channel and cannot move them; tagging them
    /// is what lets ColorSync do the Rec.2020 → display gamut conversion for
    /// free, which is the only reason this app can afford one at all.
    public var displayPreset: String? {
        guard transfer.isHDR, primaries == .rec2020 else { return nil }
        return ColorTags.rec2020Preset
    }

    /// A short human label for badges, diagnostics and the scopes' readout.
    /// Not localized on purpose: "PQ", "HLG" and "Rec.2020" are what the crew
    /// says out loud in every language on the call sheet.
    public var badge: String? {
        guard transfer.isHDR else { return nil }
        let curve = transfer == .pq ? "PQ" : "HLG"
        return primaries == .rec2020 ? "\(curve) / 2020" : curve
    }
}
