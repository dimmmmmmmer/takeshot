import Foundation

/// The input signal format detected by the capture board.
public struct CaptureFormat: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var frameRate: Double        // actual (23.976, 25, 29.97...)
    public var timecodeFPS: Int         // nominal TC numbering (24, 25, 30...)
    public var isDropFrame: Bool
    public var name: String             // human-readable: "1080p25"
    /// The source is RGB 4:4:4 delivered as full-range BGRA. HDMI cameras
    /// usually send limited-range RGB — levels "auto" expands it to full.
    public var isRGB444: Bool
    /// Bits per component the board is ACTUALLY delivering — 8, 10 or 12.
    ///
    /// What the backend settled on, not what the settings asked for, so the app
    /// can tell the operator when a request could not be met (a board or a
    /// source that cannot do 12-bit falls back, and silence there is a colour
    /// decision made behind their back). Only meaningful for RGB 4:4:4; YUV
    /// capture is 8-bit '2vuy'.
    public var bitDepth: Int

    public init(width: Int, height: Int, frameRate: Double, timecodeFPS: Int,
                isDropFrame: Bool = false, name: String, isRGB444: Bool = false,
                bitDepth: Int = 8) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.timecodeFPS = timecodeFPS
        self.isDropFrame = isDropFrame
        self.name = name
        self.isRGB444 = isRGB444
        self.bitDepth = bitDepth
    }
}

/// Recording codec.
public enum CaptureCodec: String, CaseIterable, Codable, Sendable, Identifiable {
    case proResProxy = "ProRes 422 Proxy"
    case proResLT = "ProRes 422 LT"
    case proRes422 = "ProRes 422"
    case proResHQ = "ProRes 422 HQ"
    /// The only 4:4:4 codec here, and the only one that carries 12 bits — a
    /// 12-bit RGB capture recorded as 422 is subsampled to 4:2:2 on the way in.
    case proRes4444 = "ProRes 4444"
    case h264 = "H.264"
    case hevc = "HEVC"

    public var id: String { rawValue }

    /// Whether the codec can carry a 12-bit RGB source without throwing the
    /// sampling away. Used to warn, never to override the operator's choice.
    public var isRGB444Capable: Bool { self == .proRes4444 }
}

/// Bits per component to ask the board for on an RGB 4:4:4 source.
///
/// A setting rather than a constant because the three are real trade-offs: 8
/// is BGRA and cheapest, 10 is 'r210' and has been the default since the
/// pipeline learned to split wire frames, 12 is 'R12B' and costs twice the
/// record bandwidth for two more bits that only ProRes 4444 can carry.
public enum CaptureBitDepth: String, CaseIterable, Codable, Sendable, Identifiable {
    case eight = "8"
    case ten = "10"
    case twelve = "12"

    public var id: String { rawValue }

    public var bits: Int { Int(rawValue) ?? 10 }
}

/// Resolution to decode .r3d clips at.
///
/// RED's decoder works natively at 1/1, 1/2, 1/4 and 1/8 — a reduction is less
/// work, not a resize afterwards — and a video-assist viewer wants one: an 8K
/// clip decoded full costs sixteen times a quarter-res decode to fill the same
/// 1080-class window. `auto` picks the most reduction that still fills that
/// window and is the default; the explicit rows exist for the operator who is
/// checking critical focus and will accept a slower player for it.
public enum R3DDecodeScale: String, CaseIterable, Codable, Sendable, Identifiable {
    case auto
    case full
    case half
    case quarter
    case eighth

    public var id: String { rawValue }

    /// What the bridge is asked for. 0 means "decide from the clip's width".
    public var divisor: Int {
        switch self {
        case .auto: return 0
        case .full: return 1
        case .half: return 2
        case .quarter: return 4
        case .eighth: return 8
        }
    }
}

/// Take rating: good (Good Take in Resolve) / bad / unmarked.
public enum TakeRating: String, Equatable, Sendable {
    case none
    case good
    case bad
}

/// The loop range marked on one clip, in seconds. Either end may be unset.
///
/// Lives here rather than beside the transport that owns it because the range is
/// operator work that outlives the session: it goes to the `takeshot-ranges.csv`
/// sidecar and comes back from it, and the exporter cannot see the app layer.
public struct ClipRange: Equatable, Sendable {
    public var inPoint: Double?
    public var outPoint: Double?

    public static let unset = ClipRange(inPoint: nil, outPoint: nil)

    public var isEmpty: Bool { inPoint == nil && outPoint == nil }

    public init(inPoint: Double? = nil, outPoint: Double? = nil) {
        self.inPoint = inPoint
        self.outPoint = outPoint
    }
}

/// A take — one continuous camera recording segment, one file on disk.
/// A flagged moment inside a take (hotkey during recording or review).
public struct TakeMarker: Equatable, Sendable {
    /// Marker colors (EDL locator palette; also the UI swatches).
    public static let colors = ["orange", "red", "yellow", "green",
                                "cyan", "blue", "purple"]

    /// Offset from the start of the take.
    public var seconds: Double
    /// Timecode of the moment as text (start TC + offset), when known.
    public var timecodeText: String
    /// One of `Self.colors`.
    public var color: String
    /// Free-text note (goes to the EDL locator name and the shift report).
    public var note: String

    public init(seconds: Double, timecodeText: String = "",
                color: String = "orange", note: String = "") {
        self.seconds = seconds
        self.timecodeText = timecodeText
        self.color = color
        self.note = note
    }
}

public struct Take: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public var url: URL
    /// Scene, shot and the take number within the scene — the creative side of
    /// the take, written into the .mov and carried by every export.
    public var slate: SlateMetadata = .empty
    public var roll: String
    /// The CLIP number the file was named with. Kept under its own name because
    /// it is the technical counter: it runs on for the whole roll while
    /// `slate.take` restarts with every scene.
    public var takeNumber: Int
    public var startTimecode: Timecode?
    public var durationSeconds: Double
    public var recordedAt: Date

    /// Flat accessor for the scene, which every caller had before the rest of
    /// the slate existed. One storage location, so a take cannot carry two
    /// answers to the same question.
    public var scene: String {
        get { slate.scene }
        set { slate.scene = newValue }
    }

    /// The take number editorial should see: the slate's own take when one was
    /// logged, else the clip counter — which is exactly what this app wrote
    /// into the Take columns before scenes were enterable at all, so a shift
    /// that logs no slate exports byte for byte what it always did.
    public var editorialTakeNumber: Int {
        slate.take > 0 ? slate.take : takeNumber
    }

    /// The label in the take list. Derived from the file rather than stored
    /// alongside it: both places that built a take computed exactly this, and a
    /// stored copy starts lying the moment the file is renamed underneath it.
    public var displayName: String {
        url.deletingPathExtension().lastPathComponent
    }

    // Review state. Not initializer parameters, because none of it is known
    // when a take is recorded — the operator adds it afterwards and it is
    // persisted to the sidecars rather than the file.
    public var rating: TakeRating = .none   // in CSV — Good Take + Bad marker
    public var comment: String = ""         // in CSV — Comments column
    public var markers: [TakeMarker] = []   // flagged moments (sidecar CSV)
    /// What the shot IS, as a DIT/scripty logs it — the ALE and Resolve
    /// "Description" field. Kept apart from `comment`, which is a note ABOUT
    /// the take ("boom in frame"), because post reads the two differently.
    public var logDescription: String = ""

    public init(url: URL, scene: String, roll: String = "", takeNumber: Int,
                startTimecode: Timecode?, durationSeconds: Double,
                recordedAt: Date) {
        self.url = url
        self.roll = roll
        self.takeNumber = takeNumber
        self.startTimecode = startTimecode
        self.durationSeconds = durationSeconds
        self.recordedAt = recordedAt
        self.slate.scene = scene
    }
}

/// Take start/stop detection mode.
public enum RecDetectionMode: String, CaseIterable, Codable, Sendable {
    case vanc           // VANC trigger only (default: TC-run false positives —
                        // e.g. Resolve playout runs TC — never start a take)
    case auto           // VANC trigger if recognized + running timecode
    case timecodeRun    // running TC only (camera in Rec Run)
    case manual         // in-app button only

    /// The modes a recognized VANC trigger reaches the detector in. Stated here
    /// as data, next to the cases it is about: the frame path used to spell the
    /// same set out as a condition, which is one more place to forget when a
    /// mode is added.
    public static let vancTriggerModes: Set<RecDetectionMode> = [.vanc, .auto]

    public var actsOnVancTrigger: Bool { Self.vancTriggerModes.contains(self) }
}

/// App settings (persisted in UserDefaults as JSON).
public struct CaptureSettings: Codable, Equatable, Sendable {
    public var codec: CaptureCodec = .proRes422
    public var namingTemplate: String = "{prefix}_{cam}{roll}C{clip}_{postfix}"
    public var destinationPath: String = NSSearchPathForDirectoriesInDomains(
        .moviesDirectory, .userDomainMask, true).first.map { $0 + "/TakeShot" } ?? "~/Movies/TakeShot"
    public var detectionMode: RecDetectionMode = .vanc
    /// Timecode source: nil/"rp188" — from the video stream; "ltc" — decoded
    /// from an embedded audio channel (`ltcChannel`, 0-based).
    public var timecodeSource: String?
    public var ltcChannel: Int?
    /// Capture RGB 4:4:4 sources as 10-bit r210 (nil = on; verified on the
    /// UltraStudio 4K Mini — every current Blackmagic board is 10-bit capable).
    ///
    /// Superseded by `captureBitDepth`, which can also say 12. Kept as the
    /// stored fallback so settings saved before that field existed still
    /// resolve to the depth the operator had chosen — see
    /// `resolvedCaptureBitDepth`. Nothing writes it any more.
    public var tenBitCapture: Bool?
    /// Bits per component to request for RGB 4:4:4 capture ("8"/"10"/"12");
    /// nil — fall back to `tenBitCapture`, i.e. 10-bit.
    ///
    /// Optional like every added field, so old saved JSON still decodes — and
    /// that nil is also what makes 12-bit OFF by default: nobody gets moved to
    /// a format their board may not deliver by installing an update.
    public var captureBitDepth: String?
    /// Resolution to decode .r3d clips at (`R3DDecodeScale`); nil — auto, which
    /// is enough pixels for a 1080-class viewer and no more.
    public var r3dDecodeScale: String?
    /// Bake the clip's in-camera Creative 3D LUT and CDL into R3D playback;
    /// nil — off.
    ///
    /// Off is the honest default: a viewer that silently applies someone's look
    /// is not a reference, and the operator cannot tell whether the flatness or
    /// the contrast they are judging came from the camera or from a .cube. On is
    /// the operator asking to see the look, and the player says so while it is.
    public var r3dApplyCameraLUT: Bool?
    /// Live audio monitor on/off (nil = on) — the footer speaker state.
    public var monitorEnabled: Bool?
    /// Frameline aspect (2.39, 1.85…); nil — off.
    public var framelineRatio: Double?
    /// Action/title safe-area guides.
    public var safeAreasOn: Bool?
    /// Anamorphic desqueeze factor for the preview (nil = 1).
    public var desqueezeFactor: Double?
    public var startDebounceFrames: Int = 0
    public var stopDebounceFrames: Int = 0
    public var projectName: String = ""
    public var cameraLabel: String = "A"
    /// UI language: "en" (preferred), "ru", nil — system.
    /// Optional — so old saved settings decode without a migration.
    public var appLanguage: String?
    /// Pre-roll in seconds (legacy; superseded by preRollFrames).
    public var preRollSeconds: Double?
    /// Pre-roll in frames: how many frames BEFORE the camera's record start to
    /// include. nil — 5 (or a migrated legacy seconds value).
    public var preRollFrames: Int?
    /// UI theme: "light" / "dark" / nil — system.
    public var appearance: String?
    /// Player backdrop color, hex "#RRGGBB"; nil — black.
    public var playerBackgroundHex: String?
    /// App window background color, hex; nil — system.
    public var appBackgroundHex: String?
    /// Filename postfix ({postfix} in the template).
    public var postfix: String?
    /// Bit mask of recorded channels (bit i = channel i); nil — all.
    public var audioChannelMask: Int?
    /// Audio device UID for playback output; nil — system.
    public var playbackAudioDeviceUID: String?
    /// Audio input for recording: a Core Audio input device UID (a USB
    /// interface carrying the sound cart's mix), recorded INSTEAD of the audio
    /// embedded in the capture board's signal; nil — embedded, the default.
    /// Optional, like every added field, so old saved JSON still decodes.
    public var audioInputDeviceUID: String?
    /// Control accent color, hex; nil — neutral grey.
    public var accentHex: String?
    /// DeckLink device for video-out to a monitor (SDI/HDMI); nil — off.
    public var monitorDeviceID: String?
    /// Number of digits in the clip number (C01 / C001 / C0001); nil — 2.
    public var clipPadWidth: Int?
    /// Filename of the selected LUT (in the app's LUTs folder); nil — no LUT.
    public var lutFileName: String?
    /// Apply the LUT to preview (live and playback).
    public var lutPreviewEnabled: Bool?
    /// Bake the LUT into the recorded file (otherwise a clean signal is written).
    public var lutRecordEnabled: Bool?
    /// LUT intensity 0…1 (mix with the original); nil — 1.
    public var lutIntensity: Double?
    /// Video color tags: "709" (nclc 1-1-1, default), "601", "2020".
    public var colorTagPreset: String?
    /// Input levels of the source signal: nil/"auto" — RGB 4:4:4 assumed
    /// limited; "limited" — studio swing, the whole legal swing expanded to
    /// full range so a camera's sub-blacks and super-whites survive into the
    /// file; "full" — passed through (a playout device already set to Full
    /// output levels). Legacy "off" is treated as "full" and the retired
    /// "limited_excursions" as "limited" (see `migrateToVersion2`). The values
    /// are `InputLevels` raw values, and the property stays a `String?` so
    /// settings JSON written by an older build still decodes.
    public var videoLevels: String?
    /// Live audio monitor volume 0…1; nil — 1. The monitor itself always starts
    /// OFF on launch (no surprise audio on set).
    public var monitorVolume: Double?
    /// DIM is holding monitoring down (nil/false — full level).
    ///
    /// The STATE is stored, never the halved level: `monitorVolume` stays the
    /// level the operator set, so a restored dim gives it back exactly and the
    /// lit DIM badge says why the room is quiet. Storing the halved level
    /// instead would silently make it the new base level on the next launch —
    /// the same shape of bug as persisting the mute's zero, which made every
    /// launch start silent.
    public var monitorDimmed: Bool?
    /// The speaker's full mute is holding the output at silence (nil/false —
    /// not muted).
    ///
    /// Same contract as `monitorDimmed` above: the STATE is stored, never the
    /// zero. `monitorVolume` stays the level the operator set, so an un-mute —
    /// this session or the next — gives it back exactly, and the slashed
    /// speaker in the footer says why the room is quiet. Persisting the zero
    /// itself is the bug that once made every launch start silent.
    public var monitorMuted: Bool?
    /// Color new markers are born with (one of `TakeMarker.colors`); nil — the
    /// palette's first entry.
    ///
    /// Persisted because it is a crew convention, not a per-clip choice: one
    /// unit flags focus in red and continuity in cyan all day, and re-picking it
    /// after every relaunch is how markers end up all the same color. Optional,
    /// like every other added field, so settings written by an older build still
    /// decode.
    public var defaultMarkerColor: String?
    /// Compare mode the operator left engaged (`CompareMode` raw value:
    /// "wipe"/"blend"/"difference"/"sideBySide"); nil — off, which is the
    /// default. Persisted like the wipe's orientation is not: the MODE is a
    /// working method (a unit that frames against a reference all day wants
    /// difference back after a relaunch), the seam position is a moment.
    /// Optional, like every added field, so old saved JSON still decodes.
    public var compareMode: String?
    /// Difference-compare gain multiplier (1/4/16); nil — 1.
    public var compareDifferenceGain: Int?
    /// Keep a status item in the system menu bar; nil/false — off, which is the
    /// default.
    ///
    /// Off by default for the same reason `remoteEnabled` is: an app does not
    /// take a slot in the operator's menu bar until it is asked to. With it on,
    /// a take that is rolling stays visible (and stoppable) while the main
    /// window is closed or behind other apps — closing the window has never
    /// stopped a take and still does not. Optional, like every added field, so
    /// settings written by an older build still decode.
    public var keepInMenuBar: Bool?
    /// Forced input display mode ("1080p25"…); nil — autodetect.
    public var forcedInputMode: String?
    /// With a forced mode: the signal is RGB 4:4:4 (BGRA); nil/false — YUV.
    public var forcedInputRGB: Bool?

    // MARK: - web remote (see RemoteServer and CaptureController+Remote)

    /// The browser remote is listening; nil/false — off, which is the default.
    /// A capture tool does not open a port on the set network until someone
    /// asks it to.
    public var remoteEnabled: Bool?
    /// TCP port for the remote; nil — `remotePortEffective`.
    public var remotePort: Int?
    /// Four digits, generated on first enable and shown in Settings. Stored so
    /// the same code keeps working after a relaunch — a PIN that changed every
    /// launch would have to be re-read off the laptop mid-take.
    public var remotePIN: String?

    /// Port the remote actually binds. 8765 is unassigned by IANA and outside
    /// the range macOS hands out as an ephemeral port, so it does not collide
    /// with a client socket the machine opened first.
    public var remotePortEffective: Int {
        guard let remotePort, (1024...65535).contains(remotePort) else { return 8765 }
        return remotePort
    }

    // MARK: - assist tools and zoom (see ViewAssist and the assist popover)

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
    // MARK: - chroma key (see ChromaKey and the assist popover)

    /// The screen color the keyer is set to, "#RRGGBB"; nil — digital green.
    ///
    /// The PARAMETERS persist and the on/off state deliberately does not: a
    /// keyed picture that comes back by itself after a relaunch is a preview
    /// nobody asked for, on a stage that may not even be a green one today.
    /// The dial-in is the expensive part and that is what survives — same
    /// treatment the zebra threshold and the peaking color get.
    public var chromaKeyColorHex: String?
    /// Chroma distance at which a pixel is half keyed; nil — the default.
    public var chromaKeyTolerance: Double?
    /// Feather width as a FRACTION of the tolerance, 0…1; nil — the default.
    /// It used to be an absolute distance added above the tolerance; blobs
    /// written that way are converted in `migrateToVersion3`.
    public var chromaKeySoftness: Double?
    /// Spill suppression 0…1; nil — the default.
    public var chromaKeySpill: Double?
    /// What shows through the key (`ChromaKey.Background` raw value);
    /// nil — the checkerboard.
    public var chromaKeyBackground: String?
    /// The solid background color, "#RRGGBB"; nil — black.
    public var chromaKeyBackgroundHex: String?
    /// The plate that shows through the key, as a file path; nil — none. Not
    /// necessarily a still: a take or an Other-content clip is accepted too and
    /// contributes its first frame (see `loadChromaBackground`).
    public var chromaKeyBackgroundImagePath: String?
    /// How the plate is matched to the frame (`ChromaKey.PlateFit` raw
    /// value); nil — fit.
    public var chromaKeyPlateFit: String?
    /// Magnification on top of that fit; nil — 1.
    public var chromaKeyPlateScale: Double?
    /// Plate offset as a fraction of the frame, positive x right / y up;
    /// nil — centered.
    public var chromaKeyPlateOffsetX: Double?
    public var chromaKeyPlateOffsetY: Double?

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

    /// Safe-area percentages, clamped to a range that can still be drawn.
    /// Read through these rather than the raw fields: a stored 0 (or a 400 from
    /// a hand-edited blob) would otherwise put the guides outside the picture.
    public var safeActionPercentEffective: Double {
        min(100, max(50, safeActionPercent ?? 93))
    }

    public var safeTitlePercentEffective: Double {
        min(100, max(50, safeTitlePercent ?? 90))
    }
    /// DIT offload: the destination folders of the last run, in order. The same
    /// two or three SSDs come back every shooting day, and re-picking them
    /// through a file panel per card is the part of the old flow that hurt.
    public var offloadDestinationPaths: [String]?
    /// Checksum the last offload ran with: "xxh64" (nil — the same) or
    /// "sha256". A RECORD, not a preference — the picker is gone and every run
    /// is xxHash64 now. Kept because it is written back on every run and an old
    /// saved blob still has to decode.
    public var offloadHashAlgorithm: String?

    // MARK: - dailies (see DailiesEngine and CaptureController+Dailies)
    //
    // The burn-in set is a crew convention like the marker color: one unit
    // burns the same lines all day, and re-ticking four boxes per batch is
    // how dailies end up inconsistent. All Optional, like every added field,
    // so settings JSON written by an older build still decodes.

    /// Burn the running timecode into dailies; nil — on.
    public var dailiesBurnTimecode: Bool?
    /// Burn the clip/take name; nil — on.
    public var dailiesBurnClipName: Bool?
    /// Burn the project + camera/roll line; nil — on.
    public var dailiesBurnProject: Bool?
    /// Burn the recording date; nil — off (the date is on the slate already).
    public var dailiesBurnDate: Bool?
    /// The free text line; nil/empty — no strip.
    public var dailiesCustomText: String?
    /// Where the dailies land; nil — a Dailies folder beside the takes.
    public var dailiesDestinationPath: String?
    /// Offer to offload a card the moment it is mounted; nil — on.
    ///
    /// On by default because the OFFER is safe: it is one dismissible line in
    /// the takes panel and nothing is read, written or started by it. What needs
    /// the operator's consent is the copying, and that still goes through the
    /// offload sheet exactly as it always did. Optional so a settings blob saved
    /// before this field existed still decodes.
    public var offerMountedCards: Bool?
    public var clipPadWidthEffective: Int { min(4, max(2, clipPadWidth ?? 2)) }

    /// Bits per component to request for RGB 4:4:4 capture: the explicit
    /// choice, else the legacy boolean, else 10.
    ///
    /// Reading the retired `tenBitCapture` here rather than rewriting it in a
    /// migration keeps the fallback in one expression and leaves the stored
    /// blob alone — an operator who downgrades still finds their 8-bit choice
    /// intact.
    public var resolvedCaptureBitDepth: CaptureBitDepth {
        if let captureBitDepth, let depth = CaptureBitDepth(rawValue: captureBitDepth) {
            return depth
        }
        return (tenBitCapture ?? true) ? .ten : .eight
    }

    /// Resolution to decode .r3d clips at: the operator's choice, else auto.
    public var r3dDecodeScaleEffective: R3DDecodeScale {
        r3dDecodeScale.flatMap(R3DDecodeScale.init(rawValue:)) ?? .auto
    }

    /// Effective pre-roll in frames: explicit value, else migrated legacy
    /// seconds (at 25 fps), else 5.
    public var preRollFramesEffective: Int {
        if let preRollFrames { return max(0, preRollFrames) }
        if let preRollSeconds { return max(0, Int((preRollSeconds * 25).rounded())) }
        return 5
    }

    public init() {}

    private static let defaultsKey = "TakeShot.CaptureSettings"

    /// Schema version of what this build writes. Bump it when a change cannot be
    /// expressed by "add an Optional field", and add the step to `migrate`.
    ///
    /// 1 — everything up to and including the naming-template migrations below,
    ///     which used to run unconditionally on every load.
    /// 2 — the two input-levels modes collapsed into one, and the retired
    ///     verified-backup folder handed to the offload destinations.
    /// 3 — the exposure legend moved from four corners to four edges, and the
    ///     chroma key's softness from an absolute feather to a relative one.
    ///     Both are re-readings of a value that is still in range, which is
    ///     exactly the change an Optional field cannot express.
    public static let currentSchemaVersion = 3

    /// Version of the decoded blob. Optional so that saves written before this
    /// field existed decode as nil and are treated as version 0.
    public var schemaVersion: Int?

    public static func loaded(from defaults: UserDefaults = .standard) -> CaptureSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              var settings = try? JSONDecoder().decode(CaptureSettings.self, from: data)
        else { return CaptureSettings() }
        settings = migrate(settings, retired: RetiredSettings(from: data))
        settings.schemaVersion = currentSchemaVersion
        return settings
    }

    /// Explicit, ordered migration chain. Previously every rule below ran on
    /// every load forever, which quietly forbids ever reusing an old template
    /// string and gives no place to put a change that is not a new Optional.
    ///
    /// `retired` carries the fields that are no longer on this type at all: the
    /// synthesized decoder drops unknown keys, so a migration that has to READ
    /// a removed field needs it decoded separately.
    static func migrate(_ input: CaptureSettings,
                        retired: RetiredSettings = RetiredSettings()) -> CaptureSettings {
        var settings = input
        if (settings.schemaVersion ?? 0) < 1 {
            settings = migrateToVersion1(settings)
        }
        if (settings.schemaVersion ?? 0) < 2 {
            settings = migrateToVersion2(settings, retired: retired)
        }
        if (settings.schemaVersion ?? 0) < 3 {
            settings = migrateToVersion3(settings, retired: retired)
        }
        return settings
    }

    /// The legend's corner became an edge, and the key's softness became a
    /// fraction of its tolerance.
    ///
    /// Both values would still decode as they stand and both would mean
    /// something else, which is the case a version number exists for.
    static func migrateToVersion3(
        _ input: CaptureSettings, retired: RetiredSettings) -> CaptureSettings {
        var settings = input
        // Four corners → four edges. The side the corner was on says nothing
        // about a strip that now spans the whole edge, so only top vs bottom
        // carries over — and bottom is the new default, i.e. nil.
        if settings.legendPlacement == nil,
           let corner = retired.legendCorner, corner.hasPrefix("top") {
            settings.legendPlacement = "top"
        }
        // The feather used to be an absolute chroma width hung outside the
        // tolerance (tolerance … tolerance + softness) and is now a fraction of
        // the tolerance straddling it (t·(1−s) … t·(1+s)). Converting on the
        // WIDTH keeps the edge exactly as gradual as the operator left it:
        // 2·t·new = old.
        if let stored = settings.chromaKeySoftness {
            let tolerance = settings.chromaKeyTolerance ?? ChromaKey().tolerance
            settings.chromaKeySoftness = tolerance > 0.01
                ? min(1, stored / (2 * tolerance)) : 0
        }
        return settings
    }

    /// Input levels lost their second studio-swing mode, and the app lost the
    /// verified-backup folder to the DIT offload.
    private static func migrateToVersion2(
        _ input: CaptureSettings, retired: RetiredSettings) -> CaptureSettings {
        var settings = input
        // There is one Limited now, and it is the excursion-preserving reading
        // — so the operator who had asked for that keeps exactly what they had,
        // and the one who had the clamping reading is moved off it deliberately.
        if settings.videoLevels == "limited_excursions" {
            settings.videoLevels = InputLevels.limited.rawValue
        }
        // The offload supersedes the verified backup, and its destination list
        // is where that folder belongs. Adopted only when the operator has not
        // already set one up: their own list is never second-guessed.
        if settings.offloadDestinationPaths == nil, let backup = retired.backupPath {
            settings.offloadDestinationPaths = [backup]
        }
        return settings
    }

    private static func migrateToVersion1(_ input: CaptureSettings) -> CaptureSettings {
        var settings = input
        // migrate default templates from earlier versions
        if ["{scene}_T{take}_{cam}_{tc}",
            "{prefix}_{cam}_{roll}_C{clip}",
            "{prefix}_{cam}_{roll}_C{clip}_{postfix}"].contains(settings.namingTemplate) {
            settings.namingTemplate = CaptureSettings().namingTemplate
        }
        // presets from before the vendor date formats ({date6}/{date4}/{time4})
        let presetMigrations = [
            "{cam}{roll}C{clip}_{date}_{postfix}": "{cam}{roll}C{clip}_{date6}_{postfix}",
            "{cam}{roll}_C{clip}_{date}_{postfix}": "{cam}{roll}_C{clip}_{date4}{postfix}",
            "{cam}{roll}C{clip}_{date}{postfix}": "{cam}{roll}C{clip}_{date6}{postfix}",
            "{cam}{roll}_{date}_C{clip}": "{cam}{roll}_{date4}{time4}_C{clip}",
        ]
        for (old, new) in [("{date6}", "{yymmdd}"), ("{date4}", "{mmdd}"),
                           ("{time4}", "{hhmm}"), ("{time6}", "{hhmmss}")] {
            settings.namingTemplate =
                settings.namingTemplate.replacingOccurrences(of: old, with: new)
        }
        if let migrated = presetMigrations[settings.namingTemplate] {
            settings.namingTemplate = migrated
        }
        return settings
    }

    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}

/// Increment/decrement naming fields (roll "001" → "002", camera A → B).
public enum FieldStepper {
    /// Changes a string's trailing digits, preserving leading zeros: "001"+1 → "002",
    /// "A12"+1 → "A13". With no trailing digits the string is unchanged.
    public static func stepTrailingNumber(_ value: String, by delta: Int) -> String {
        guard let range = value.range(of: "[0-9]+$", options: .regularExpression),
              let number = Int(value[range]) else { return value }
        let width = value.distance(from: range.lowerBound, to: range.upperBound)
        let next = max(0, number + delta)
        return value[..<range.lowerBound] + String(format: "%0\(width)d", next)
    }

    /// Steps the last A-Z letter through the alphabet (wrapping): "A"+1 → "B", "Z"+1 → "A".
    public static func stepLetter(_ value: String, by delta: Int) -> String {
        guard let last = value.unicodeScalars.last,
              last.value >= 65, last.value <= 90 else { return value }
        let index = Int(last.value) - 65
        let next = ((index + delta) % 26 + 26) % 26
        return String(value.unicodeScalars.dropLast())
            + String(UnicodeScalar(UInt8(65 + next)))
    }
}
