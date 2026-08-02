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
    /// Clip/take name, bottom-left.
    public var clipName = true
    /// Project plus camera/roll, bottom-right.
    public var project = true
    /// Recording date — it shares the bottom-right strip with the project line
    /// (the classic layout has four corners and this set has five facts).
    public var date = false
    /// Free text, top-left. Empty — no strip.
    public var customText = ""

    public init() {}

    public init(timecode: Bool, clipName: Bool, project: Bool, date: Bool,
                customText: String) {
        self.timecode = timecode
        self.clipName = clipName
        self.project = project
        self.date = date
        self.customText = customText
    }

    /// Nothing is burned in at all — the run is a plain transcode.
    public var isEmpty: Bool {
        !timecode && !clipName && !project && !date && customText.isEmpty
    }
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
public struct DailiesItemResult: Sendable, Equatable {
    public var source: URL
    /// The finished .mp4; nil when the item failed or was cancelled.
    public var output: URL?
    /// Why the item failed. A failed item never stops the queue — it is
    /// marked, skipped, and the next one starts.
    public var failure: String?
    public var wasCancelled: Bool

    public init(source: URL, output: URL? = nil, failure: String? = nil,
                wasCancelled: Bool = false) {
        self.source = source
        self.output = output
        self.failure = failure
        self.wasCancelled = wasCancelled
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

    /// Every queued take came out as a daily.
    public var isFullySucceeded: Bool {
        !items.isEmpty && items.allSatisfy { $0.output != nil }
    }
}
