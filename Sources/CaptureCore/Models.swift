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

    public init(width: Int, height: Int, frameRate: Double, timecodeFPS: Int,
                isDropFrame: Bool = false, name: String, isRGB444: Bool = false) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.timecodeFPS = timecodeFPS
        self.isDropFrame = isDropFrame
        self.name = name
        self.isRGB444 = isRGB444
    }
}

/// Recording codec.
public enum CaptureCodec: String, CaseIterable, Codable, Sendable, Identifiable {
    case proResProxy = "ProRes 422 Proxy"
    case proResLT = "ProRes 422 LT"
    case proRes422 = "ProRes 422"
    case proResHQ = "ProRes 422 HQ"
    case h264 = "H.264"
    case hevc = "HEVC"

    public var id: String { rawValue }
}

/// Take rating: good (Good Take in Resolve) / bad / unmarked.
public enum TakeRating: String, Equatable, Sendable {
    case none
    case good
    case bad
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
    public var id: UUID
    public var url: URL
    public var displayName: String
    public var scene: String
    public var roll: String
    public var takeNumber: Int
    public var startTimecode: Timecode?
    public var durationSeconds: Double
    public var rating: TakeRating       // good/bad take (in CSV — Good Take + NG marker)
    public var comment: String          // free-text note (in CSV — Comments column)
    public var recordedAt: Date
    public var markers: [TakeMarker]    // flagged moments (sidecar CSV)

    public init(id: UUID = UUID(), url: URL, displayName: String, scene: String,
                roll: String = "", takeNumber: Int, startTimecode: Timecode?,
                durationSeconds: Double, rating: TakeRating = .none,
                comment: String = "", recordedAt: Date,
                markers: [TakeMarker] = []) {
        self.id = id
        self.url = url
        self.displayName = displayName
        self.scene = scene
        self.roll = roll
        self.takeNumber = takeNumber
        self.startTimecode = startTimecode
        self.durationSeconds = durationSeconds
        self.rating = rating
        self.comment = comment
        self.recordedAt = recordedAt
        self.markers = markers
    }
}

/// Take start/stop detection mode.
public enum RecDetectionMode: String, CaseIterable, Codable, Sendable {
    case vanc           // VANC trigger only (default: TC-run false positives —
                        // e.g. Resolve playout runs TC — never start a take)
    case auto           // VANC trigger if recognized + running timecode
    case timecodeRun    // running TC only (camera in Rec Run)
    case manual         // in-app button only
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
    /// Capture RGB 4:4:4 sources as 10-bit r210 (nil = on).
    public var tenBitCapture: Bool?
    /// Live audio monitor on/off (nil = on) — the footer speaker state.
    public var monitorEnabled: Bool?
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
    /// How many leading audio channels to write (deprecated, replaced by the mask).
    public var recordChannelCount: Int?
    /// Bit mask of recorded channels (bit i = channel i); nil — all.
    public var audioChannelMask: Int?
    /// Audio device UID for playback output; nil — system.
    public var playbackAudioDeviceUID: String?
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
    /// limited; "limited" (16-235) — expanded once to full-range BGRA;
    /// "full" (0-255) — passed through (a playout device already set to Full
    /// output levels). Legacy "off" is treated as "full".
    public var videoLevels: String?
    /// Live audio monitor volume 0…1; nil — 1. The monitor itself always starts
    /// OFF on launch (no surprise audio on set).
    public var monitorVolume: Double?
    /// Forced input display mode ("1080p25"…); nil — autodetect.
    public var forcedInputMode: String?
    /// With a forced mode: the signal is RGB 4:4:4 (BGRA); nil/false — YUV.
    public var forcedInputRGB: Bool?
    public var clipPadWidthEffective: Int { min(4, max(2, clipPadWidth ?? 2)) }

    public var preRollSecondsEffective: Double { preRollSeconds ?? 1.0 }

    /// Effective pre-roll in frames: explicit value, else migrated legacy
    /// seconds (at 25 fps), else 5.
    public var preRollFramesEffective: Int {
        if let preRollFrames { return max(0, preRollFrames) }
        if let preRollSeconds { return max(0, Int((preRollSeconds * 25).rounded())) }
        return 5
    }

    public init() {}

    private static let defaultsKey = "TakeShot.CaptureSettings"

    public static func loaded(from defaults: UserDefaults = .standard) -> CaptureSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              var settings = try? JSONDecoder().decode(CaptureSettings.self, from: data)
        else { return CaptureSettings() }
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
