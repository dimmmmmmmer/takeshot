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
        case timecodePosition = "dailiesTimecodePosition"
        case clipNamePosition = "dailiesClipNamePosition"
        case projectPosition = "dailiesProjectPosition"
        case customPosition = "dailiesCustomPosition"
        case datePosition = "dailiesDatePosition"
        case burnCustom = "dailiesBurnCustom"
        case codec = "dailiesCodec"
        case resolution = "dailiesResolution"
        case variants = "dailiesVariants"
        case normalizeAudio = "dailiesNormalizeAudio"
        case bakeLook = "dailiesBakeLook"
        case bakeDesqueeze = "dailiesBakeDesqueeze"
        case namePrefix = "dailiesNamePrefix"
        case nameSuffix = "dailiesNameSuffix"
        case plateOpacity = "dailiesPlateOpacity"
        case textOpacity = "dailiesTextOpacity"
        case customPlateOpacity = "dailiesCustomPlateOpacity"
        case customTextOpacity = "dailiesCustomTextOpacity"
        case sourcePaths = "dailiesSourcePaths"
        case soundPaths = "dailiesSoundPaths"
        case goodTakesOnly = "dailiesGoodTakesOnly"
        case skipFinished = "dailiesSkipFinished"
        case extraDestinationPaths = "dailiesExtraDestinationPaths"
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
    /// Where each burned-in line sits (`DailiesBurninPosition` raw values);
    /// nil — the classic arrangement, which is what each `…Effective` below
    /// answers.
    ///
    /// Persisted because it is a crew convention rather than a per-clip
    /// choice, and stored as nil at the default like every added field, so
    /// settings written by an older build still decode.
    public var timecodePosition: String?
    public var clipNamePosition: String?
    public var projectPosition: String?
    public var customPosition: String?
    public var datePosition: String?
    /// Whether the custom line is burned in.
    ///
    /// **nil is not "off" here, it is "ask the old blob what it meant".** The
    /// custom line used to be its own switch — a non-empty text WAS the on
    /// state — so a settings file from before this field says nothing about a
    /// flag and everything about intent: text present means the operator had
    /// the line on. `burnCustomEffective` reads it that way, which is what
    /// keeps an upgrade from quietly dropping a line somebody was burning.
    public var burnCustom: Bool?
    /// Codec for the dailies (`CaptureCodec` raw values); nil — H.264, which
    /// is what every daily was before the choice existed.
    public var codec: String?
    /// **How far a daily is scaled down** (`DailiesResolution` raw values);
    /// nil — 1080p, which is what every daily was before the choice existed
    /// (owner: "во, точно, давай сделаем выбор насколько снижать резолюшн").
    ///
    /// Persisted because it is a delivery convention rather than a per-batch
    /// choice: a show sends 720p rushes all season, and re-picking it for
    /// every batch is how one day's dailies arrive at the wrong size.
    public var resolution: String?
    /// **The extra versions a run also produces** (owner: "очередь из
    /// нескольких вариантов дейликов"), each as one string — see
    /// `DailiesVariant.stored` for why a string and not an object.
    ///
    /// nil/empty is the ordinary case and is the whole compatibility story: a
    /// run with no extras is the run this app has always made.
    public var variants: [String]?
    /// **Bring every review copy to the same level**; nil — off.
    ///
    /// Off is the honest default, like the baked look beside it: every daily
    /// this app has written carries the sound the take had, and a level this
    /// app decided cannot be taken back out of a proxy.
    public var normalizeAudio: Bool?
    /// **Bake the viewing look into the proxies** (owner: "о в дейликах хочу
    /// еще возможность чтоб лут в них запекался").
    ///
    /// nil is OFF, and deliberately not "ask an older blob what it meant":
    /// every daily this app has written was clean, and a look silently baked
    /// into a proxy cannot be taken out of it again.
    public var bakeLook: Bool?
    /// **Take the anamorphic squeeze out of the proxies** (owner: "и думаю еще
    /// можно настройку сделать чтоб десквиз запекать").
    ///
    /// nil is OFF, like `bakeLook` and for the same reason: every daily this
    /// app has written carries the camera's own raster, and a proxy silently
    /// stretched is one an editor cuts with at the wrong shape.
    ///
    /// The factor is not stored here — it is the operator's own
    /// `AssistSettings.desqueezeApplied`, the one the viewer is already using,
    /// because a daily made at a different squeeze from the picture it was
    /// approved on is two answers to one question.
    public var bakeDesqueeze: Bool?
    /// Put in front of / after the take's name in the output file name;
    /// nil — nothing in front and "_DAILY" after, the name this app has
    /// always written.
    public var namePrefix: String?
    public var nameSuffix: String?
    /// How solid the burn-ins are: the plate and the lettering, for the
    /// technical lines and for the custom line separately (`DailiesInk`).
    /// nil — the standard ink, which is what every daily has carried.
    public var plateOpacity: Double?
    public var textOpacity: Double?
    public var customPlateOpacity: Double?
    public var customTextOpacity: Double?
    /// Folders the last run rendered FROM; nil/empty — the day's takes.
    ///
    /// Stored like the offload's destination list and for the same reason: the
    /// same card tree and the same shuttle drive come back every shooting day,
    /// and re-picking them through a file panel per batch is the part of the
    /// old flow that hurt.
    public var sourcePaths: [String]?
    /// **Folders of the sound recordist's files** (owner: "было бы классно
    /// иметь возможность выбрать папку со звуком"). Empty — the daily carries
    /// the camera's own sound and nothing else, which is what it always did.
    public var soundPaths: [String]?
    /// Destinations beyond the first — the shelves each daily is copied to.
    public var extraDestinationPaths: [String]?

    public init() {}

    /// The four positions, resolved. Read through these rather than the raw
    /// fields: a hand-edited blob naming a position that does not exist must
    /// land on the classic arrangement rather than draw nothing.
    public var timecodePositionEffective: DailiesBurninPosition {
        timecodePosition.flatMap(DailiesBurninPosition.init(rawValue:)) ?? .topCenter
    }

    public var clipNamePositionEffective: DailiesBurninPosition {
        clipNamePosition.flatMap(DailiesBurninPosition.init(rawValue:)) ?? .bottomLeft
    }

    public var projectPositionEffective: DailiesBurninPosition {
        projectPosition.flatMap(DailiesBurninPosition.init(rawValue:)) ?? .bottomRight
    }

    public var customPositionEffective: DailiesBurninPosition {
        customPosition.flatMap(DailiesBurninPosition.init(rawValue:)) ?? .topLeft
    }

    public var datePositionEffective: DailiesBurninPosition {
        datePosition.flatMap(DailiesBurninPosition.init(rawValue:)) ?? .bottomRight
    }

    /// Whether the custom line is on, reading an older blob's intent when the
    /// flag was never written (see `burnCustom`).
    public var burnCustomEffective: Bool {
        burnCustom ?? !(customText ?? "").isEmpty
    }

    /// The ceiling, resolved. An unreadable value lands on 1080p rather than
    /// on the source's own raster: a blob naming a case this build does not
    /// know must not start a run that writes 6K ProRes to a shuttle drive.
    public var resolutionEffective: DailiesResolution {
        resolution.flatMap(DailiesResolution.init(rawValue:)) ?? .hd
    }

    /// The extra variants, resolved. One unreadable entry is dropped and the
    /// rest are kept — the same leniency every other list in this blob has,
    /// because one mangled row must not cost an operator the others — and the
    /// list is capped where the model caps it, so a hand-edited blob cannot
    /// ask for forty passes over a night's footage.
    public var variantsEffective: [DailiesVariant] {
        Array((variants ?? []).compactMap(DailiesVariant.init(stored:))
            .prefix(DailiesVariant.limit))
    }

    /// The codec, resolved. Restricted to `dailiesChoices`: a blob naming
    /// ProRes 4444 — or a codec that has since left the list — lands on H.264
    /// rather than starting a run that writes a daily bigger than the take.
    public var codecEffective: CaptureCodec {
        guard let codec, let parsed = CaptureCodec(rawValue: codec),
              CaptureCodec.dailiesChoices.contains(parsed) else { return .h264 }
        return parsed
    }

    /// **The output name's two ends.** The suffix defaults to `_DAILY`, which
    /// is what this app has always appended, so a blob from before these
    /// fields produces byte-identical names.
    ///
    /// Both are stored as the operator typed them and sanitized where the name
    /// is built (`DailiesQueueModel.item`), not here: a settings accessor that
    /// silently rewrote what was typed is the divergence `NameTextField` was
    /// introduced to end.
    public var namePrefixEffective: String { namePrefix ?? "" }

    public var nameSuffixEffective: String { nameSuffix ?? "_DAILY" }

    /// The folders a run renders from, as URLs. Empty — the day's takes.
    public var sourceURLs: [URL] {
        (sourcePaths ?? []).map { URL(fileURLWithPath: $0) }
    }

    /// **Render only the circled takes** (owner: "давай еще сделаем галку
    /// где-нибудь типа рендерить только удачные тейки"). nil/false — the whole
    /// day, which is what a dailies run has always been.
    public var goodTakesOnly: Bool?

    /// **Leave alone what the destination already holds** (owner: "не
    /// рендерить уже отрендеренное — точно да"). nil — ON, which is the
    /// default a second run over the same day needs: without it every daily
    /// gets a `_2` beside it.
    public var skipFinished: Bool?

    /// What the switch reads, nil included.
    public var skipFinishedEffective: Bool { skipFinished ?? true }

    /// The sound folders, as URLs. Empty — camera sound only.
    public var soundURLs: [URL] {
        (soundPaths ?? []).map { URL(fileURLWithPath: $0) }
    }

    /// The shelves beyond the first.
    public var extraDestinationURLs: [URL] {
        (extraDestinationPaths ?? []).map { URL(fileURLWithPath: $0) }
    }

    /// The technical lines' ink, resolved.
    public var inkEffective: DailiesInk {
        DailiesInk(plate: plateOpacity ?? DailiesInk.standard.plate,
                   text: textOpacity ?? DailiesInk.standard.text)
    }

    /// …and the custom line's own.
    public var customInkEffective: DailiesInk {
        DailiesInk(plate: customPlateOpacity ?? DailiesInk.standard.plate,
                   text: customTextOpacity ?? DailiesInk.standard.text)
    }
}

/// The DIT offload: where it copies to, and whether it offers itself.
public struct OffloadSettings: Codable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey {
        case destinationPaths = "offloadDestinationPaths"
        case sourcePaths = "offloadSourcePaths"
        case offerMountedCards
    }

    /// The destination folders of the last run, in order. The same two or three
    /// SSDs come back every shooting day, and re-picking them through a file
    /// panel per card is the part of the old flow that hurt.
    public var destinationPaths: [String]?
    /// The cards the last run was pointed at.
    ///
    /// Stored for the reason the owner noticed it was not (" он не сохранил
    /// после шатдауна задачку оффлоада последнюю"): a copy interrupted by a
    /// crash or a quit is resumed from the same card, and re-picking it
    /// through a file panel is the part of that the operator should not have
    /// to do twice. Restored only for cards still MOUNTED — a path to a card
    /// that has been unplugged is not a card, and a list of dead paths is a
    /// list nobody trusts (the same rule the dailies source list follows).
    public var sourcePaths: [String]?
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
