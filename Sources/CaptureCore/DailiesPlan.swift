import Foundation

/// What one dailies run burns into every frame. Each line is toggleable; the
/// custom line doubles as its own toggle (empty — no strip).
///
/// The queue's choices, not an item's: a day's dailies carry one convention,
/// and per-clip toggles would be twenty switches nobody asked for.
public struct DailiesBurnins: Sendable, Equatable {
    /// Running timecode, top-center — from the take's timecode track (every
    /// sample, so a mid-take Rec Run re-anchor stays frame-accurate), or from
    /// the start TC plus frame math when the file has no track.
    public var timecode = true
    /// Clip/take name.
    public var clipName = true
    /// The project name.
    public var project = true
    /// Recording date, bottom-right — its own strip, stacked under the project
    /// line when both are on and both are pointed there.
    public var date = false
    /// Free text, top-left. Empty — no strip.
    public var customText = ""
    /// **Where each line sits, and these five are the owner's own
    /// arrangement** — they set them on the sheet and said "вот какие
    /// дефолтные настройки должны быть": the clock bottom-left, the clip name
    /// bottom-right, the project across the top, and neither the date nor a
    /// custom line switched on. The operator can move any of them (see
    /// `DailiesBurninPosition`).
    public var timecodePosition: DailiesBurninPosition = .bottomLeft
    public var clipNamePosition: DailiesBurninPosition = .bottomRight
    public var projectPosition: DailiesBurninPosition = .topCenter
    public var customPosition: DailiesBurninPosition = .topLeft
    public var datePosition: DailiesBurninPosition = .bottomRight
    /// How solid the technical lines are, and the custom line separately —
    /// the plate and the lettering each (`DailiesInk`).
    public var ink: DailiesInk = .standard
    public var customInk: DailiesInk = .standard

    public init() {}

    public init(timecode: Bool, clipName: Bool, project: Bool, date: Bool,
                customText: String,
                timecodePosition: DailiesBurninPosition = .bottomLeft,
                clipNamePosition: DailiesBurninPosition = .bottomRight,
                projectPosition: DailiesBurninPosition = .topCenter,
                customPosition: DailiesBurninPosition = .topLeft,
                datePosition: DailiesBurninPosition = .bottomRight,
                ink: DailiesInk = .standard,
                customInk: DailiesInk = .standard) {
        self.timecode = timecode
        self.clipName = clipName
        self.project = project
        self.date = date
        self.customText = customText
        self.timecodePosition = timecodePosition
        self.clipNamePosition = clipNamePosition
        self.projectPosition = projectPosition
        self.customPosition = customPosition
        self.datePosition = datePosition
        self.ink = ink
        self.customInk = customInk
    }

    /// Nothing is burned in at all — the run is a plain transcode.
    public var isEmpty: Bool {
        !timecode && !clipName && !project && !date && customText.isEmpty
    }
}

public extension CaptureCodec {
    /// **The codecs a daily is worth writing in** (owner: "дейлики хочу
    /// выбирать по кодеку").
    ///
    /// A subset of the app's one codec vocabulary rather than an enum of its
    /// own: `CaptureCodec` already names these, already maps to AVFoundation
    /// and already knows which of them take a bitrate, and a parallel dailies
    /// enum would be a second spelling of the same product names — the mistake
    /// `LivePicture` is injected into the remote pages to avoid.
    ///
    /// The three heavier ProRes flavours are deliberately absent: a daily is a
    /// review copy, and 422/HQ/4444 produce a file at or above the size of the
    /// take it was made from. Order is lightest-to-heaviest within each family,
    /// H.264 first because it is the one every review station opens.
    static var dailiesChoices: [CaptureCodec] {
        [.h264, .hevc, .proResProxy, .proResLT]
    }

    /// **Every daily is a `.mov`, whatever the codec** (owner: "давай и не
    /// рендерить в мп4. только в мовы все").
    ///
    /// It used to follow the codec — H.264 and HEVC into `.mp4`, ProRes into
    /// `.mov`, because MPEG-4 Part 14 has no registered sample entry for
    /// ProRes. That half is still true and is now moot: QuickTime carries
    /// every codec offered here, and an MPEG-4 file cannot carry three things
    /// this app puts in a daily — the take's reverse-DNS metadata keys, a
    /// `tmcd` timecode track, and a NAME on a sound track. All three are
    /// measured refusals of the MPEG-4 writer, and all three are exactly what
    /// makes a daily worth conforming from.
    ///
    /// What it costs: a `.mov` is a less familiar extension to a web upload
    /// form than an `.mp4`, and the BYTES are identical — an H.264 elementary
    /// stream in a QuickTime container is what every NLE, QuickTime, VLC and
    /// every browser this decade opens. `DailiesSession` still asks the writer
    /// itself (`canApply(outputSettings:forMediaType:)`), because this being
    /// right is not the same as it staying right.
    var dailiesFileExtension: String { "mov" }
}

/// One take in the dailies queue: the recorded file, the output name, and the
/// facts the burn-ins state about it. The app composes the text lines because
/// it owns the settings they come from; the engine only draws what it is told.
public struct DailiesItem: Sendable, Equatable {
    /// The finished take (.mov). Read-only — dailies never touch a recording.
    public var source: URL
    /// Output file name without extension ("A001C01_DAILY"). The extension is
    /// the engine's (.mp4), and collisions get the app's usual `_2` suffix.
    public var outputName: String
    /// The bottom-left strip, when enabled.
    public var clipName: String
    /// Project plus camera/roll ("MyFilm · A001"), bottom-right when enabled.
    public var projectLine: String
    /// Recording date as text; joins the bottom-right strip when enabled.
    public var dateText: String
    /// Fallback for the timecode burn-in when the file has no timecode track.
    public var startTimecode: Timecode?

    public init(source: URL, outputName: String, clipName: String,
                projectLine: String = "", dateText: String = "",
                startTimecode: Timecode? = nil) {
        self.source = source
        self.outputName = outputName
        self.clipName = clipName
        self.projectLine = projectLine
        self.dateText = dateText
        self.startTimecode = startTimecode
    }
}

/// The queue's remote control: cancel everything, skip one item, and the
/// recording-protection pause.
///
/// A class with a lock, like `OffloadCancellation` and for the same reason:
/// the engine polls between frames on its own task while the UI (and the REC
/// state) write from the main thread. Pause is a level, not an event — the
/// engine finishes the frame in hand and then waits, so a recording never
/// competes with `TakeWriter` for the disk or the encoder.
public final class DailiesControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelAll = false
    private var skippedItem: Int?
    private var paused = false

    public init() {}

    /// Stop the whole queue. The frame in hand finishes, the partial output is
    /// deleted, and every item not reached is reported as cancelled.
    public func cancel() {
        lock.withLock { cancelAll = true }
    }

    public var isCancelled: Bool {
        lock.withLock { cancelAll }
    }

    /// Skip one item (by queue index): its partial output is deleted and the
    /// next item starts. Index-keyed so a skip pressed as the item finishes
    /// cannot leak onto the item after it.
    public func skip(item index: Int) {
        lock.withLock { skippedItem = index }
    }

    public func isSkipped(item index: Int) -> Bool {
        lock.withLock { skippedItem == index }
    }

    /// The recording gate. True while the app records; the engine holds
    /// between frames until it drops.
    public func setPaused(_ value: Bool) {
        lock.withLock { paused = value }
    }

    public var isPaused: Bool {
        lock.withLock { paused }
    }
}

/// Live state of the queue, published as one value so the UI never renders a
/// mix of two moments (same contract as `OffloadProgress`).
public struct DailiesProgress: Sendable, Equatable {
    /// 0-based index of the item in flight.
    public var itemIndex: Int
    public var itemCount: Int
    /// File name of the take being transcoded.
    public var currentFile: String
    public var framesDone: Int
    public var framesTotal: Int
    /// The recording gate is holding the queue.
    public var isPaused: Bool
    public var isCancelling: Bool

    public init(itemIndex: Int, itemCount: Int, currentFile: String,
                framesDone: Int, framesTotal: Int, isPaused: Bool,
                isCancelling: Bool) {
        self.itemIndex = itemIndex
        self.itemCount = itemCount
        self.currentFile = currentFile
        self.framesDone = framesDone
        self.framesTotal = framesTotal
        self.isPaused = isPaused
        self.isCancelling = isCancelling
    }

    /// Queue-level fraction for the one bar the status strip draws: whole
    /// items done plus the fraction of the item in flight.
    public var overallFraction: Double {
        guard itemCount > 0 else { return 0 }
        let item = framesTotal > 0
            ? min(1, Double(framesDone) / Double(framesTotal)) : 0
        return min(1, (Double(itemIndex) + item) / Double(itemCount))
    }
}

/// How one item ended: exactly one of `output` / `failure` / plain cancel.
/// **A look to bake into the proxies**, with the name that goes on the file.
///
/// The cube and its name travel together because the file has to say WHICH
/// look is in its pixels: `com.takeshot.lut` is what stops a player — or a
/// second run of dailies — from grading the same picture twice, and a key with
/// no name in it would say a look is baked without saying which one, which is
/// the same as saying nothing to anybody reading the file next year.
///
/// The intensity is the operator's own mix, the same number the viewing look
/// is applied at: a daily baked at full strength from a look the operator is
/// watching at 60 % would not be the picture they approved.
public struct DailiesLook: Sendable {
    public var cube: CubeLUT
    public var name: String
    public var intensity: Double

    public init(cube: CubeLUT, name: String, intensity: Double = 1) {
        self.cube = cube
        self.name = name
        self.intensity = intensity
    }
}

public struct DailiesItemResult: Sendable, Equatable {
    public var source: URL
    /// The finished .mp4; nil when the item failed or was cancelled.
    public var output: URL?
    /// Why the item failed. A failed item never stops the queue — it is
    /// marked, skipped, and the next one starts.
    public var failure: String?
    public var wasCancelled: Bool
    /// **The daily was already there and this run left it alone** (owner: "не
    /// рендерить уже отрендеренное — точно да").
    ///
    /// `output` is set, because the file exists and the operator asked for it
    /// — an item that is skipped is a succeeded item, not an absent one. The
    /// flag is what lets the report say "30 already rendered, 12 made" instead
    /// of claiming a day's work it did not do.
    public var wasSkipped: Bool = false
    /// Extra destinations this daily could not be copied to, and why.
    ///
    /// Not a failure of the ITEM: the daily exists, and a report that called
    /// it failed would be telling the operator the footage has no daily when
    /// it has one. It is a line in the result panel about a shelf.
    public var copyFailures: [String] = []

    public init(source: URL, output: URL? = nil, failure: String? = nil,
                wasCancelled: Bool = false, wasSkipped: Bool = false) {
        self.source = source
        self.output = output
        self.failure = failure
        self.wasCancelled = wasCancelled
        self.wasSkipped = wasSkipped
    }
}

/// The run as a whole, in queue order.
public struct DailiesReport: Sendable, Equatable {
    public var items: [DailiesItemResult]
    /// Cancel actually cut the run short (same rule as the offload report:
    /// Stop pressed during the last frame of the last item is not a cancelled
    /// run — every daily exists).
    public var wasCancelled: Bool

    public init(items: [DailiesItemResult], wasCancelled: Bool) {
        self.items = items
        self.wasCancelled = wasCancelled
    }

    public var completed: [DailiesItemResult] {
        items.filter { $0.output != nil }
    }

    public var failed: [DailiesItemResult] {
        items.filter { $0.failure != nil }
    }

    /// The ones that were already in the folder — see
    /// `DailiesItemResult.wasSkipped`.
    public var skipped: [DailiesItemResult] {
        items.filter { $0.wasSkipped }
    }

    /// The ones this run actually encoded.
    public var rendered: [DailiesItemResult] {
        items.filter { $0.output != nil && !$0.wasSkipped }
    }

    /// Every queued take came out as a daily.
    public var isFullySucceeded: Bool {
        !items.isEmpty && items.allSatisfy { $0.output != nil }
    }
}
