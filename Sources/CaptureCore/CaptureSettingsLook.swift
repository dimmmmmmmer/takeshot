import Foundation

// What the operator LOOKS at: the app's own chrome, the aids drawn over the
// picture, the review controls, the preview LUT, and the RAW decode.
//
// The four groups below strip a common prefix off the persisted key
// (`lutFileName` is `lut.fileName`, `r3dDecodeScale` is `r3d.decodeScale`) —
// that prefix WAS the namespace, hand-maintained in every field name because
// there was nowhere to put it. `SettingsGroupNamingTests` proves the stripping
// is exact, field by field, so a group can never quietly re-point a key at a
// different property.

/// The app's own appearance — theme, backdrops, accent, and whether it keeps a
/// status item. Persisted under the names it always had.
public struct ThemeSettings: Codable, Equatable, Sendable {
    /// UI language: "en" (preferred), "ru", nil — system.
    /// Optional — so old saved settings decode without a migration.
    public var appLanguage: String?
    /// UI theme: "light" / "dark" / nil — system.
    public var appearance: String?
    /// Player backdrop color, hex "#RRGGBB"; nil — black.
    public var playerBackgroundHex: String?
    /// App window background color, hex; nil — system.
    public var appBackgroundHex: String?
    /// Control accent color, hex; nil — neutral grey.
    public var accentHex: String?
    /// Keep a status item in the system menu bar; nil/false — off, which is the
    /// default.
    ///
    /// Off by default for the same reason `RemoteSettings.enabled` is: an app
    /// does not take a slot in the operator's menu bar until it is asked to.
    /// With it on, a take that is rolling stays visible (and stoppable) while
    /// the main window is closed or behind other apps — closing the window has
    /// never stopped a take and still does not. Optional, like every added
    /// field, so settings written by an older build still decode.
    public var keepInMenuBar: Bool?

    public init() {}
}

/// The aids drawn over the picture: framelines, safe areas, the anamorphic
/// desqueeze, the exposure legend and focus peaking.
public struct AssistSettings: Codable, Equatable, Sendable {
    /// Frameline aspect (2.39, 1.85…). The VALUE, kept whether the guide is
    /// drawn or not — see `framelinesOn`.
    public var framelineRatio: Double?
    /// Whether the framelines are drawn.
    ///
    /// **A switch of its own, so switching off does not forget the aspect.**
    /// Off used to be `framelineRatio = nil`, which was the same statement
    /// back when the picker carried an Off row — with a checkbox beside it
    /// (owner: "давай и у фреймлайнов и у десквиза вместо опции офф тоже
    /// сделаем галочки слева как у остальных пунктов") that spelling throws
    /// away the 2.39 the operator set, every time they untick the box.
    ///
    /// nil reads the old blob's intent: a stored aspect meant the guide was
    /// on, which is exactly what it meant before this field existed.
    public var framelinesOn: Bool?
    /// Action/title safe-area guides.
    public var safeAreasOn: Bool?
    /// Anamorphic desqueeze factor. The VALUE, like `framelineRatio` and for
    /// the same reason — `desqueezeOn` decides whether it is applied.
    public var desqueezeFactor: Double?
    /// Whether the desqueeze is applied. nil reads intent: a stored factor
    /// other than 1 meant it was on.
    public var desqueezeOn: Bool?
    /// Action-safe area as a percentage of the frame; nil — 93.
    ///
    /// 93/90 and in that order, per SMPTE RP 218 (EBU R 95 states the same two
    /// as 3.5% and 5% insets): TITLE safe is the tighter box and lives INSIDE
    /// action safe. Assigning the pair the other way round draws the title
    /// guide outside the action guide, which is not a safe-area diagram at all —
    /// it just tells the operator two contradictory things about the same frame.
    public var safeActionPercent: Double?
    /// Title-safe area as a percentage of the frame; nil — 90 (see above).
    public var safeTitlePercent: Double?
    /// Safe-area line brightness, 0.05…1; nil — full. See
    /// `safeBrightnessEffective`.
    public var safeBrightness: Double?
    /// Exposure-legend size: "s" / "m" / "l"; nil — medium. The legend is read
    /// from behind the camera, so its size is the operator's call, not ours.
    public var legendSize: String?
    /// Which edge of the player the legend sits against
    /// (`AssistLegendPlacement`); nil — bottom, centered.
    ///
    /// Replaces the four corners this used to be (`legendCorner`, migrated in
    /// `migrateToVersion3`): a legend is a strip, and a strip belongs along an
    /// edge — vertical down the left or the right, horizontal centered along
    /// the top or the bottom.
    public var legendPlacement: String?
    /// Focus-peaking overlay color (`ViewAssist.PeakingColor` raw value);
    /// nil — red. A crew convention like the marker color, so it survives a
    /// relaunch. Optional, like every added field, so old saved JSON decodes.
    public var peakingColor: String?
    /// Focus-peaking edge gain — the RENDERER's unit (`CIEdges` intensity),
    /// not the percentage the panel shows; nil — the default 12.
    ///
    /// The renderer's unit on purpose: the percentage is a presentation of it
    /// (`ViewAssist.peakingPercent`), and storing the presentation would mean a
    /// change to the scale silently re-tuned every operator's saved setting.
    public var peakingIntensity: Double?

    /// The aspect a frameline is drawn at when the guide is switched on and
    /// nothing has ever been chosen. 2.39 is the one a set asks for first.
    public static let defaultFramelineRatio = 2.39
    /// …and the factor a desqueeze is applied at on the same terms. 2x is the
    /// classic anamorphic squeeze.
    public static let defaultDesqueezeFactor = 2.0

    /// Whether the framelines are drawn, reading an older blob's intent when
    /// the flag was never written.
    public var framelinesOnEffective: Bool {
        framelinesOn ?? (framelineRatio != nil)
    }

    /// The aspect the picker shows — the operator's choice, whether the guide
    /// is being drawn or not.
    public var framelineRatioChosen: Double {
        guard let framelineRatio, framelineRatio > 0 else {
            return Self.defaultFramelineRatio
        }
        return framelineRatio
    }

    /// **What the renderer draws**: nil when the guide is off, whatever aspect
    /// is remembered. One conversion, so the value drawn and the value the
    /// popover edits cannot disagree about what "off" means.
    public var framelineRatioDrawn: Double? {
        framelinesOnEffective ? framelineRatioChosen : nil
    }

    /// Whether the desqueeze is applied, reading intent for an older blob.
    public var desqueezeOnEffective: Bool {
        desqueezeOn ?? ((desqueezeFactor ?? 1) != 1)
    }

    /// The factor the picker shows, on or off.
    public var desqueezeFactorChosen: Double {
        guard let desqueezeFactor, desqueezeFactor > 0 else {
            return Self.defaultDesqueezeFactor
        }
        return desqueezeFactor
    }

    /// What the renderer applies — 1 is "no squeeze", which is what off means
    /// to every stage downstream.
    public var desqueezeApplied: Double {
        desqueezeOnEffective ? desqueezeFactorChosen : 1
    }

    public init() {}  /// Safe-area percentages, clamped to a range that can still be drawn.
    /// Read through these rather than the raw fields: a stored 0 (or a 400 from
    /// a hand-edited blob) would otherwise put the guides outside the picture.
    public var safeActionPercentEffective: Double {
        min(100, max(50, safeActionPercent ?? 93))
    }

    public var safeTitlePercentEffective: Double {
        min(100, max(50, safeTitlePercent ?? 90))
    }

    /// **How bright the safe-area lines are** (owner: "добавь в сейфзоны
    /// ползунок настройки их яркости"). nil — full, which is what they have
    /// always been drawn at; the floor is 5 % rather than 0 because a switched
    /// ON aid that draws nothing is a switch that looks broken.
    public var safeBrightnessEffective: Double {
        min(1, max(0.05, safeBrightness ?? 1))
    }
}

/// What the operator left engaged in review: the compare mode and the colour
/// new markers are born with.
public struct ReviewSettings: Codable, Equatable, Sendable {
    /// Compare mode the operator left engaged (`CompareMode` raw value:
    /// "wipe"/"blend"/"difference"/"sideBySide"); nil — off, which is the
    /// default. Persisted like the wipe's orientation is not: the MODE is a
    /// working method (a unit that frames against a reference all day wants
    /// difference back after a relaunch), the seam position is a moment.
    /// Optional, like every added field, so old saved JSON still decodes.
    public var compareMode: String?
    /// **Retired.** The difference-compare gain multiplier (1/4/16); nil — 1.
    ///
    /// The picker is gone and nothing reads or writes this any more: a
    /// difference is a measurement, and a multiplier the operator cannot read
    /// off the picture is a way to be wrong about one (owner: "кроме х1 смысла
    /// не вижу в них"). The key stays on the record so a blob carrying it still
    /// decodes and a build that downgrades finds its value — the tombstone
    /// contract `RetiredSettingTests` states.
    public var compareDifferenceGain: Int?
    /// Whether a reference pinned from a video take PLAYS or holds as a still.
    ///
    /// nil is PLAYS, which is what the owner asked for ("реф видео из плейбека
    /// при пине на странице река не играет как видео а остается стиллом") —
    /// one of the few added fields whose nil is not "off", because the
    /// behaviour it turns on is the one that was reported missing. Persisted
    /// on the argument `compareMode` makes two fields up: it is a working
    /// method, not a moment.
    public var referencePlays: Bool?
    public var referencePlaysEffective: Bool { referencePlays ?? true }
    /// Color new markers are born with (one of `TakeMarker.colors`); nil — the
    /// palette's first entry.
    ///
    /// Persisted because it is a crew convention, not a per-clip choice: one
    /// unit flags focus in red and continuity in cyan all day, and re-picking it
    /// after every relaunch is how markers end up all the same color. Optional,
    /// like every other added field, so settings written by an older build still
    /// decode.
    public var defaultMarkerColor: String?

    public init() {}
}

/// The preview/record LUT. Persisted as `lut…`, which is the prefix this group
/// strips.
public struct LUTSettings: Codable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey {
        case fileName = "lutFileName"
        case folderPath = "lutFolderPath"
        case previewEnabled = "lutPreviewEnabled"
        case recordEnabled = "lutRecordEnabled"
        case intensity = "lutIntensity"
    }

    /// Filename of the selected LUT (in the app's LUTs folder); nil — no LUT.
    public var fileName: String?
    /// The look library the operator pointed the app at; nil — the app's own
    /// Application Support folder, which is where imports land.
    ///
    /// A path and not a bookmark: the folder a unit keeps its looks in is on
    /// the show drive next to the record folder, which is stored the same way
    /// (`CaptureSettings.capture.destinationPath`) and for the same reason —
    /// the operator can read it back, and a drive that comes up under a
    /// different mount point is a broken path they can see rather than a
    /// bookmark that silently resolves somewhere else. Optional, like every
    /// added field, so settings written by an older build still decode.
    public var folderPath: String?
    /// Apply the LUT to preview (live and playback).
    public var previewEnabled: Bool?
    /// Bake the LUT into the recorded file (otherwise a clean signal is written).
    public var recordEnabled: Bool?
    /// LUT intensity 0…1 (mix with the original); nil — 1.
    public var intensity: Double?

    public init() {}
}

/// RED .r3d playback. Persisted as `r3d…`.
public struct R3DSettings: Codable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey {
        case decodeScale = "r3dDecodeScale"
        case applyCameraLUT = "r3dApplyCameraLUT"
    }

    /// Resolution to decode .r3d clips at (`R3DDecodeScale`); nil — auto, which
    /// is enough pixels for a 1080-class viewer and no more.
    public var decodeScale: String?
    /// Bake the clip's in-camera Creative 3D LUT and CDL into R3D playback;
    /// nil — off.
    ///
    /// Off is the honest default: a viewer that silently applies someone's look
    /// is not a reference, and the operator cannot tell whether the flatness or
    /// the contrast they are judging came from the camera or from a .cube. On is
    /// the operator asking to see the look, and the player says so while it is.
    public var applyCameraLUT: Bool?

    public init() {}

    /// Resolution to decode .r3d clips at: the operator's choice, else auto.
    public var decodeScaleEffective: R3DDecodeScale {
        decodeScale.flatMap(R3DDecodeScale.init(rawValue:)) ?? .auto
    }
}
