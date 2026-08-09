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
    /// decision made behind their back).
    ///
    /// Meaningful for both samplings: RGB 4:4:4 is 8 ('BGRA'), 10 ('r210') or 12
    /// ('R12B'), and YCbCr 4:2:2 is 8 ('2vuy') or 10 ('v210'). It used to be
    /// documented as RGB-only, because YUV capture was 8-bit and nothing else.
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

/// Bits per component to ask the board for.
///
/// A setting rather than a constant because the three are real trade-offs: 8
/// is BGRA and cheapest, 10 is 'r210' and has been the default since the
/// pipeline learned to split wire frames, 12 is 'R12B' and costs twice the
/// record bandwidth for two more bits that only ProRes 4444 can carry.
///
/// ONE setting for both samplings rather than two pickers, because "how many
/// bits do I want off the wire" is one question an operator asks once. The wire
/// format it names differs — see `bits` for RGB 4:4:4 and `yuvBits` for
/// YCbCr 4:2:2 — and so does what a board is likely to do with the request:
/// 12-bit RGB is exotic and often refused, 10-bit YCbCr is the baseline SDI
/// format and effectively always available.
public enum CaptureBitDepth: String, CaseIterable, Codable, Sendable, Identifiable {
    case eight = "8"
    case ten = "10"
    case twelve = "12"

    public var id: String { rawValue }

    /// Bits to request from an RGB 4:4:4 source: 8 'BGRA', 10 'r210', 12 'R12B'.
    public var bits: Int { Int(rawValue) ?? 10 }

    /// Bits to request from a YCbCr 4:2:2 source: 8 '2vuy' or 10 'v210'.
    ///
    /// 12 means 10 here, and that is not a rounding-down of the operator's
    /// wish — there IS no 12-bit YCbCr wire format in the SDK, so 'v210' is the
    /// deepest thing a 4:2:2 signal can be asked for. Someone who selected 12
    /// asked for as many bits as the wire has, and on a YCbCr wire that is ten.
    public var yuvBits: Int { self == .eight ? 8 : 10 }
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
