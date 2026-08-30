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
    /// What the backend settled on, not what the signal said, so the app can
    /// tell the operator when the wire's depth could not be met (a board or a
    /// mode that cannot do 12-bit falls back, and silence there is a colour
    /// decision made behind their back).
    ///
    /// Meaningful for both samplings: RGB 4:4:4 is 8 ('BGRA'), 10 ('r210') or 12
    /// ('R12B'), and YCbCr 4:2:2 is 8 ('2vuy') or 10 ('v210'). It used to be
    /// documented as RGB-only, because YUV capture was 8-bit and nothing else.
    public var bitDepth: Int
    /// Bits per component the SOURCE is sending — 8, 10 or 12 — or nil when the
    /// board did not say.
    ///
    /// The other depth. `bitDepth` above is the app's side of the exchange and
    /// this is the wire's, and keeping them apart is the whole point: the app
    /// used to report the depth it had itself requested as though the signal had
    /// stated it, which made "the source is 12-bit" a thing no screen in the app
    /// could say.
    ///
    /// nil is a real answer and not a zero. A forced input mode fires no
    /// detection callback at all, a DeckLink header set older than the depth
    /// flags cannot report it, and the demo source is not a board — in all three
    /// the honest reading is "unknown", which is not the same decision as 8.
    public var sourceBitDepth: Int?

    public init(width: Int, height: Int, frameRate: Double, timecodeFPS: Int,
                isDropFrame: Bool = false, name: String, isRGB444: Bool = false,
                bitDepth: Int = 8, sourceBitDepth: Int? = nil) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.timecodeFPS = timecodeFPS
        self.isDropFrame = isDropFrame
        self.name = name
        self.isRGB444 = isRGB444
        self.bitDepth = bitDepth
        self.sourceBitDepth = sourceBitDepth
    }

    /// The deepest capture this signal can yield, or nil when the source's own
    /// depth is unknown and there is therefore nothing to measure against.
    ///
    /// One rule, and it is the sampling's rather than the board's: RGB 4:4:4 can
    /// be captured at whatever the source sends, and YCbCr 4:2:2 tops out at ten
    /// however deep the source is, because there is no 12-bit 4:2:2 wire format
    /// in the SDK — 'v210' is as deep as a 4:2:2 signal goes. That used to be
    /// stated as `CaptureBitDepth.yuvBits`, about a request an operator made;
    /// it is the same truth about the wire, now asked of the wire.
    ///
    /// This is what "did the board fall short" is measured against, so a 12-bit
    /// YCbCr source captured as 'v210' is silence rather than a complaint the
    /// operator can do nothing about.
    public var capturableBitDepth: Int? {
        guard let sourceBitDepth else { return nil }
        return isRGB444 ? sourceBitDepth : min(sourceBitDepth, 10)
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
    /// sampling away. Used to warn, never to override the operator's choice —
    /// `CaptureController.BitDepthNotice.twelveBit` is the warning, and it
    /// became a real one when depth started following the signal: a 12-bit
    /// source used to arrive because the operator had clicked for it, so the
    /// codec beside it was a pair they had chosen.
    public var isRGB444Capable: Bool { self == .proRes4444 }
}

// `CaptureBitDepth` stood here: one setting, 8/10/12, asked of both samplings.
// It is gone, and its absence is the feature. The format-detection callback has
// always carried the source's own depth — the app read the sampling bit out of
// those flags and filled the depth in from the pixel format it had itself
// requested — so the picker was the app asking the operator a question the wire
// had already answered, and answering it wrong cost either two bits of picture
// or twice the bandwidth. Depth now follows the signal (`CaptureFormat`'s two
// depth fields above, and the bridge's `rgbPixelFormatForMode:sourceBits:`), and
// there is deliberately no override: an operator cannot be right about the
// number of bits on the wire against the wire itself, which is the same reason
// there is no "force HDR".

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
    /// The camera's own REC indicator, watched in a box on the picture.
    ///
    /// A MODE and not a switch beside them. It was a `Toggle` of its own, which
    /// made it look like a modifier on whatever mode was chosen when it is an
    /// alternative to them — and worse, it could not be turned on until the box
    /// was taught while the teaching rows lived under the same switch, so an
    /// untaught install found a control that did nothing (owner: "рек индикатор
    /// в настройках не переключается вообще... это должна быть одна из опций
    /// для река среди ванк/таймкод и прочего").
    ///
    /// It is the answer for HDMI, where there is no ancillary data to carry a
    /// trigger at all and a camera that does not run Rec Run timecode leaves
    /// nothing else to watch.
    case visual

    /// The modes a recognized VANC trigger reaches the detector in. Stated here
    /// as data, next to the cases it is about: the frame path used to spell the
    /// same set out as a condition, which is one more place to forget when a
    /// mode is added.
    public static let vancTriggerModes: Set<RecDetectionMode> = [.vanc, .auto]

    /// The modes that watch the camera's own REC indicator. `auto` is here
    /// because auto means "every kind of evidence this signal offers", and on
    /// an HDMI camera with no running timecode the indicator is the only kind
    /// there is. An untaught box simply contributes nothing.
    public static let visualModes: Set<RecDetectionMode> = [.visual, .auto]

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
