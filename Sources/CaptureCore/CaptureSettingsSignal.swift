import Foundation

// The signal path, the filename, and the sound — the three groups of
// `CaptureSettings` that describe what is captured rather than how it is
// looked at.
//
// Every field here keeps the NAME it is persisted under. The encoded blob is
// flat (see `CaptureSettings`'s `Codable`), so a property name here is a key
// on disk and renaming one resets that setting for every existing operator.

/// Everything about getting the signal off the board and into a file.
public struct CaptureSignalSettings: Codable, Equatable, Sendable {
    public var codec: CaptureCodec = .proRes422
    public var destinationPath: String = NSSearchPathForDirectoriesInDomains(
        .moviesDirectory, .userDomainMask, true).first.map { $0 + "/TakeShot" } ?? "~/Movies/TakeShot"
    public var detectionMode: RecDetectionMode = .vanc
    /// Timecode source: nil/"rp188" — from the video stream; "ltc" — decoded
    /// from an embedded audio channel (`ltcChannel`, 0-based).
    public var timecodeSource: String?
    public var ltcChannel: Int?
    /// INERT. A retired 10-bit-capture switch, kept as a key on the record so
    /// that a blob carrying it still decodes and an operator who downgrades
    /// still finds it where they left it.
    ///
    /// Nothing reads it and nothing writes it: bit depth follows the signal and
    /// there is no depth setting for it to fall back to. It stays in the record
    /// rather than being removed because removing a key is a change to the
    /// on-disk format, and this one buys nothing.
    public var tenBitCapture: Bool?
    // `captureBitDepth` was a key here ("8"/"10"/"12"). It is gone from the
    // record, not merely unread: bit depth follows the signal and there is no
    // setting for a stored value to mean anything to. A blob that still carries
    // the key decodes exactly as before — the synthesized decoder drops keys it
    // does not know, which is what makes removing one safe — and this build
    // writes it back without.
    //
    // No `RetiredSettings` entry and no schema bump, deliberately. That pair
    // exists for a field a MIGRATION has to read once, and there is nowhere for
    // this one to be read into: the operator who had chosen 8-bit to save
    // bandwidth is moved to what their camera is actually sending, which is the
    // whole change. `anOldBlobWithARetiredBitDepthStillDecodes` holds the half
    // of the contract that is real.
    public var startDebounceFrames: Int = 0
    public var stopDebounceFrames: Int = 0
    /// Pre-roll in seconds (legacy; superseded by preRollFrames).
    public var preRollSeconds: Double?
    /// Pre-roll in frames: how many frames BEFORE the camera's record start to
    /// include. nil — 5 (or a migrated legacy seconds value).
    public var preRollFrames: Int?
    /// Forced input display mode ("1080p25"…); nil — autodetect.
    public var forcedInputMode: String?
    /// With a forced mode: the signal is RGB 4:4:4 (BGRA); nil/false — YUV.
    public var forcedInputRGB: Bool?
    /// Input levels of the source signal: nil/"auto" — RGB 4:4:4 assumed
    /// limited; "limited" — studio swing, the whole legal swing expanded to
    /// full range so a camera's sub-blacks and super-whites survive into the
    /// file; "full" — passed through (a playout device already set to Full
    /// output levels). Legacy "off" is treated as "full" and the retired
    /// "limited_excursions" as "limited" (see `migrateToVersion2`). The values
    /// are `InputLevels` raw values, and the property stays a `String?` so
    /// settings JSON written by an older build still decodes.
    public var videoLevels: String?
    /// Video color tags: "709" (nclc 1-1-1, default), "601", "2020". An HDR
    /// source overrides this for its own takes — the file has to state the
    /// transfer the camera really sent (see `WireColorimetry.filePreset`).
    public var colorTagPreset: String?
    /// What the app does with a source reporting PQ or HLG: nil/"auto" — follow
    /// the signal; "off" — treat every source as SDR, which is exactly how the
    /// app behaved before HDR existed. `HDRMode` raw values; Optional like every
    /// added field so settings JSON written by an older build still decodes.
    public var hdrMode: String?
    /// DeckLink device for video-out to a monitor (SDI/HDMI); nil — off.
    public var monitorDeviceID: String?

    public init() {}

    /// Effective pre-roll in frames: explicit value, else migrated legacy
    /// seconds (at 25 fps), else 5.
    public var preRollFramesEffective: Int {
        if let preRollFrames { return max(0, preRollFrames) }
        if let preRollSeconds { return max(0, Int((preRollSeconds * 25).rounded())) }
        return 5
    }
}

/// What the file is called. `projectName` is the `{prefix}` the operator types
/// into the footer, so it lives with the template rather than with the project.
public struct NamingSettings: Codable, Equatable, Sendable {
    public var namingTemplate: String = "{prefix}_{cam}{roll}C{clip}_{postfix}"
    public var projectName: String = ""
    public var cameraLabel: String = "A"
    /// Filename postfix ({postfix} in the template).
    public var postfix: String?
    /// Number of digits in the clip number (C01 / C001 / C0001); nil — 2.
    public var clipPadWidth: Int?

    public init() {}

    public var clipPadWidthEffective: Int { min(4, max(2, clipPadWidth ?? 2)) }
}

/// The monitor speaker, what is recorded, and where playback goes out.
public struct AudioSettings: Codable, Equatable, Sendable {
    /// Live audio monitor on/off (nil = on) — the footer speaker state.
    public var monitorEnabled: Bool?
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
    /// Bit mask of recorded channels (bit i = channel i); nil — all.
    public var audioChannelMask: Int?
    /// Audio device UID for playback output; nil — system.
    public var playbackAudioDeviceUID: String?
    /// Audio input for recording: a Core Audio input device UID (a USB
    /// interface carrying the sound cart's mix), recorded INSTEAD of the audio
    /// embedded in the capture board's signal; nil — embedded, the default.
    /// Optional, like every added field, so old saved JSON still decodes.
    public var audioInputDeviceUID: String?

    public init() {}
}
