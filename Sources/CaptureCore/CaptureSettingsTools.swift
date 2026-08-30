import Foundation

// The tools an operator dials in once and expects to find as they left them:
// the chroma key, the taught REC indicator, the dailies burn-in set, and the
// DIT offload's destinations.
//
// Each strips the prefix its keys were already carrying — `chromaKeyPlateOffsetX`
// is `chromaKey.plateOffsetX` — and the persisted names are unchanged.

/// The chroma keyer's dial-in.
///
/// The PARAMETERS persist and the on/off state deliberately does not: a keyed
/// picture that comes back by itself after a relaunch is a preview nobody asked
/// for, on a stage that may not even be a green one today. The dial-in is the
/// expensive part and that is what survives — same treatment the zebra
/// threshold and the peaking colour get.
public struct ChromaKeySettings: Codable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey {
        case colorHex = "chromaKeyColorHex"
        case tolerance = "chromaKeyTolerance"
        case softness = "chromaKeySoftness"
        case spill = "chromaKeySpill"
        case background = "chromaKeyBackground"
        case backgroundHex = "chromaKeyBackgroundHex"
        case backgroundImagePath = "chromaKeyBackgroundImagePath"
        case plateFit = "chromaKeyPlateFit"
        case plateScale = "chromaKeyPlateScale"
        case plateOffsetX = "chromaKeyPlateOffsetX"
        case plateOffsetY = "chromaKeyPlateOffsetY"
    }

    /// The screen color the keyer is set to, "#RRGGBB"; nil — digital green.
    public var colorHex: String?
    /// Chroma distance at which a pixel is half keyed; nil — the default.
    public var tolerance: Double?
    /// Feather width as a FRACTION of the tolerance, 0…1; nil — the default.
    /// It used to be an absolute distance added above the tolerance; blobs
    /// written that way are converted in `migrateToVersion3`.
    public var softness: Double?
    /// Spill suppression 0…1; nil — the default.
    public var spill: Double?
    /// What shows through the key (`ChromaKey.Background` raw value);
    /// nil — the checkerboard.
    public var background: String?
    /// The solid background color, "#RRGGBB"; nil — black.
    public var backgroundHex: String?
    /// The plate that shows through the key, as a file path; nil — none. Not
    /// necessarily a still: a take or an Other-content clip is accepted too and
    /// contributes its first frame (see `loadChromaBackground`).
    public var backgroundImagePath: String?
    /// How the plate is matched to the frame (`ChromaKey.PlateFit` raw
    /// value); nil — fit.
    public var plateFit: String?
    /// Magnification on top of that fit; nil — 1.
    public var plateScale: Double?
    /// Plate offset as a fraction of the frame, positive x right / y up;
    /// nil — centered.
    public var plateOffsetX: Double?
    public var plateOffsetY: Double?

    public init() {}
}

/// The taught REC indicator (see `VisualRecTrigger`).
///
/// The TEACHING persists and the switch deliberately does not — the same split
/// the chroma key has, and here for a stronger reason: the references are a
/// photograph of one camera's overlay in one framing, and a trigger that
/// re-arms itself at launch on a rig it was never taught on is the false start
/// this feature is most able to cause. Marking the box and capturing two
/// references is the expensive part, so that is what survives. All Optional,
/// like every added field, so settings written by an older build still decode.
public struct VisualRecSettings: Codable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey {
        case centerX = "visualRecCenterX"
        case centerY = "visualRecCenterY"
        case size = "visualRecSize"
        case width = "visualRecWidth"
        case height = "visualRecHeight"
        case margin = "visualRecMargin"
        case rolling = "visualRecRolling"
        case idle = "visualRecIdle"
    }

    /// Centre of the watched box, in SIGNAL fractions (y down); nil — centre of
    /// frame, which is where an untaught box sits.
    public var centerX: Double?
    public var centerY: Double?
    /// The old SQUARE extent, kept so settings written before the box had two
    /// axes still decode — and still restore, as both of them. Nothing writes
    /// it any more: `persistVisualRec` writes the pair below, so the first save
    /// after an upgrade retires it. Read in `restoreVisualRec`, which is the
    /// only place it may be read; `RetiredSettingTests` holds that line.
    public var size: Double?
    /// Box extent as a fraction of each axis; nil — `VisualRecRegion.defaultSize`.
    ///
    /// Two, because a camera's REC indicator is a dot beside a word — wide and
    /// short — and a square that holds it holds a strip of moving picture with
    /// it (see `VisualRecRegion.width`).
    public var width: Double?
    public var height: Double?
    /// Required margin against the other reference, as a fraction of the taught
    /// separation; nil — `VisualRecTeaching.defaultMargin`.
    public var margin: Double?
    /// The two references, base64 of one byte per signature component (see
    /// `VisualRecSignature.encoded`); nil — not taught. 256 characters each,
    /// which is why they are not stored as arrays of JSON numbers.
    public var rolling: String?
    public var idle: String?

    public init() {}
}

/// The dailies burn-in set and where the batch lands.
///
/// The burn-in set is a crew convention like the marker color: one unit burns
/// the same lines all day, and re-ticking four boxes per batch is how dailies
/// end up inconsistent. All Optional, like every added field, so settings JSON
/// written by an older build still decodes.
public struct DailiesSettings: Codable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey {
        case burnTimecode = "dailiesBurnTimecode"
        case burnClipName = "dailiesBurnClipName"
        case burnProject = "dailiesBurnProject"
        case burnDate = "dailiesBurnDate"
        case customText = "dailiesCustomText"
        case destinationPath = "dailiesDestinationPath"
    }

    /// Burn the running timecode into dailies; nil — on.
    public var burnTimecode: Bool?
    /// Burn the clip/take name; nil — on.
    public var burnClipName: Bool?
    /// Burn the project + camera/roll line; nil — on.
    public var burnProject: Bool?
    /// Burn the recording date; nil — off (the date is on the slate already).
    public var burnDate: Bool?
    /// The free text line; nil/empty — no strip.
    public var customText: String?
    /// Where the dailies land; nil — a Dailies folder beside the takes.
    public var destinationPath: String?

    public init() {}
}

/// The DIT offload: where it copies to, and whether it offers itself.
public struct OffloadSettings: Codable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey {
        case destinationPaths = "offloadDestinationPaths"
        case offerMountedCards
    }

    /// The destination folders of the last run, in order. The same two or three
    /// SSDs come back every shooting day, and re-picking them through a file
    /// panel per card is the part of the old flow that hurt.
    public var destinationPaths: [String]?
    /// Offer to offload a card the moment it is mounted; nil — on.
    ///
    /// On by default because the OFFER is safe: it is one dismissible line in
    /// the takes panel and nothing is read, written or started by it. What needs
    /// the operator's consent is the copying, and that still goes through the
    /// offload sheet exactly as it always did. Optional so a settings blob saved
    /// before this field existed still decodes.
    ///
    /// Persisted WITHOUT the group's prefix, unlike its neighbour — the key
    /// predates the offload owning it. Kept as it is rather than renamed: the
    /// key is the contract, and tidying it would cost every operator the
    /// setting. `SettingsGroupNamingTests` allows exactly this shape and checks
    /// it is still an exact mapping.
    public var offerMountedCards: Bool?

    public init() {}
}
