import Foundation

/// What the look is doing to the clip under review, and therefore what the
/// filter button beside the transport may say about it.
///
/// # Why this is one function
///
/// Two things asked this and they were not asking it the same way.
/// `applyPlaybackLUT` is the truth — it is what actually reaches
/// `PlaybackFrameTap` — and it asks four questions: is preview on, is the look
/// already in the file's pixels, has this clip had it switched off, and is
/// there a cube to apply. The transport bar's filter icon asked two of the
/// four, so it could light in the accent colour over a picture with no look on
/// it at all, and offer a toggle for switching off something that was not on.
///
/// That state is reachable and not exotic: `selectLUT(fileName: nil)` clears
/// the look and deliberately leaves `previewEnabled` alone, so clearing the
/// look library while preview is on leaves `lutPreviewOn` true with no cube.
/// The bar then drew the ON tint. An indicator that is lit when nothing is
/// happening is worse than no indicator: the operator's next move is to go
/// looking for the look they can see is applied.
///
/// So the rule is stated once, over the four facts, and both the bar and the
/// tap read it. The bar cannot show a state the picture is not in, because it
/// is the same answer.
enum PlaybackLook: Equatable {
    /// Nothing to apply and nothing to offer: no look picked, its cube did not
    /// load, or preview is off. The bar shows no filter control at all.
    case none
    /// The file already carries the look in its own pixels (our own take,
    /// tagged `com.takeshot.lut`). Nothing to switch, so the bar shows an
    /// INDICATOR and not a button — a toggle here would appear to take a look
    /// off that no amount of pressing can reach.
    case baked
    /// A look is being applied to the review picture right now.
    case applied
    /// A look is picked and preview is on, and this clip has it switched off
    /// (the look came from the camera, say). The only difference from
    /// `applied` is which way the toggle is pointing.
    case suppressed

    /// Whether the tap should be given the cube. The one place that answers it.
    var appliesCube: Bool { self == .applied }

    /// Whether the bar offers a control the operator can press. `baked` is the
    /// case this exists for: it is visible and it is not pressable.
    var isSwitchable: Bool { self == .applied || self == .suppressed }

    /// The rule, over the four facts that decide it.
    ///
    /// `baked` is tested FIRST and outranks everything, including preview being
    /// off: the codes in the file carry the look whatever the app is set to, so
    /// saying "no look" over a baked take would be a false negative about the
    /// footage rather than about a setting.
    static func current(previewEnabled: Bool, hasCube: Bool,
                        fileHasBakedLook: Bool, suppressed: Bool) -> PlaybackLook {
        if fileHasBakedLook { return .baked }
        guard previewEnabled, hasCube else { return .none }
        return suppressed ? .suppressed : .applied
    }
}
