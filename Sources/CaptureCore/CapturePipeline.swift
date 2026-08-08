@preconcurrency import AVFoundation
@preconcurrency import CoreImage
@preconcurrency import CoreMedia
@preconcurrency import CoreVideo
import Foundation
import os.log

/// Frame pipeline: takes backend callbacks (from capture threads), runs them
/// through RecDetector, writes takes via TakeWriter, and feeds preview. All work
/// happens on its own serial queue; only UI events hop to the MainActor.
///
/// This file holds the state and the contracts that go with it; the behaviour
/// lives in the domain extensions — `+Control` (what the MainActor asks for),
/// `+Input` (what the backends deliver), `+Frame` (the per-frame path),
/// `+Take`, `+Preview` and `+Audio`. State that a sibling extension touches is
/// internal rather than private for that reason, never wider than the module.
///
/// @unchecked Sendable: all mutable state is touched only on `queue`; UI callbacks
/// are assigned once before capture starts and invoked on main.
public final class CapturePipeline: @unchecked Sendable {
    public struct Config: Sendable {
        public var settings: CaptureSettings
        /// The creative values the NEXT take will be slated with.
        public var slate: SlateMetadata
        public var roll: String
        public var takeNumber: Int

        /// Flat accessor kept for the callers that only ever set a scene.
        public var scene: String {
            get { slate.scene }
            set { slate.scene = newValue }
        }

        public init(settings: CaptureSettings, slate: SlateMetadata = .empty,
                    roll: String = "", takeNumber: Int) {
            self.settings = settings
            self.slate = slate
            self.roll = roll
            self.takeNumber = takeNumber
        }
    }

    // UI callbacks, invoked on the main queue
    public var onFormatChanged: ((CaptureFormat?) -> Void)?
    public var onTimecode: ((Timecode?) -> Void)?
    public var onRecStateChanged: ((Bool) -> Void)?
    public var onSignal: ((Bool) -> Void)?
    /// The signal's colorimetry, whenever it changes — what lights the HDR
    /// badge and switches the scopes' scale into nits. Delivered on main.
    public var onColorimetry: ((WireColorimetry) -> Void)?

    /// These two are the only callbacks read away from the main queue: the
    /// detached finalize task snapshots them on its own thread (see
    /// `takeReport`). Every other callback above is both written and read on
    /// main, so a plain property is fine for them — these two are not.
    ///
    /// A closure property is a two-word value with an ARC-managed context. Read
    /// it on one thread while another writes it and you get a function pointer
    /// paired with the wrong context, which crashes with whatever signal the
    /// garbage happens to earn — SIGBUS on one machine, SIGSEGV on the next,
    /// and nothing at all on the machine you develop on. `displayFrameHandler`
    /// below already carries a lock for exactly this reason; these were left
    /// bare when the finalize task moved off the main queue, and it crashed CI
    /// on every push for a week.
    private let takeCallbackLock = NSLock()
    private var storedOnTakeFinished: ((Take) -> Void)?
    private var storedOnError: ((PipelineAlarm) -> Void)?

    public var onTakeFinished: ((Take) -> Void)? {
        get { takeCallbackLock.withLock { storedOnTakeFinished } }
        set { takeCallbackLock.withLock { storedOnTakeFinished = newValue } }
    }

    /// Something went wrong, as a `PipelineAlarm` rather than as prose: the
    /// consumer reads `severity` to decide how loudly to say it, and picks its
    /// own wording from the case. See `PipelineAlarm` for why it is not a
    /// String any more.
    public var onError: ((PipelineAlarm) -> Void)? {
        get { takeCallbackLock.withLock { storedOnError } }
        set { takeCallbackLock.withLock { storedOnError = newValue } }
    }
    /// VANC packet stats (for the monitor); sent about once a second on changes.
    public var onVancStats: (([VancPacketStat]) -> Void)?
    /// Per-channel audio peak levels, dBFS. Arrive at the audio-packet rate (~25 Hz).
    public var onAudioLevels: (([Float]) -> Void)?
    /// Scope data (waveform + histograms) from the displayed frame, up to
    /// `scopeUpdatesPerSecond` while enabled via setScopesEnabled. Delivered on
    /// the main queue.
    public var onScopeData: ((ScopeData) -> Void)?
    /// Stereo monitor feed (first two enabled channels) while audio monitoring
    /// is on. Delivered on the pipeline queue — the consumer re-queues itself.
    public var onMonitorAudio: ((CMSampleBuffer) -> Void)?
    /// What the taught record indicator reads, whenever it CHANGES — at most a
    /// few times a second, and never while the trigger is disarmed. Delivered on
    /// the main queue; it is what lets the operator see the box working before
    /// trusting a take to it (see `+VisualRec`).
    ///
    /// A plain property, like `onScopeData` beside it and unlike the two above:
    /// it is assigned once when the controller binds the pipeline and read from
    /// the watcher's queue thereafter, never re-routed while frames are in
    /// flight, which is the condition the two locked ones fail.
    public var onVisualRecReading: ((VisualRecReading?) -> Void)?

    /// The two callbacks a finalizing take needs, snapshotted so the detached
    /// finish task can hand results to the main queue without sending the
    /// pipeline itself across isolation.
    struct TakeReport: @unchecked Sendable {
        let finished: (Take) -> Void
        let failed: (PipelineAlarm) -> Void
    }

    /// Both callbacks copied out under one lock, so the task holds values
    /// rather than a reference to the pipeline's mutable state.
    var takeReport: TakeReport {
        takeCallbackLock.withLock {
            TakeReport(finished: { [storedOnTakeFinished] in storedOnTakeFinished?($0) },
                       failed: { [storedOnError] in storedOnError?($0) })
        }
    }

    /// Live preview sinks: every SwiftUI mount registers its OWN layer (a
    /// CALayer can be hosted by only one NSView; see PreviewSinkRegistry).
    public let displaySinks = PreviewSinkRegistry()
    /// Every displayed frame, on the display queue — hardware playout mirror.
    /// Re-routed from the main actor on every record/playback switch while the
    /// display queue is calling it, so it goes through a lock: a plain closure
    /// property is a two-word value with an ARC-managed context, and a torn
    /// read releases the box under the reader's feet.
    let displayFrameLock = NSLock()
    var displayFrameHandler: (@Sendable (CVPixelBuffer) -> Void)?
    /// A second mirror for the phone camera grid — of the CLEAN processed
    /// frame, not of what the viewer draws (see `enqueuePreview`).
    /// Its own slot rather than a list: `displayFrameHandler` is owned by the
    /// hardware playout mirror and re-routed on every record/playback switch,
    /// and sharing it would take the operator's monitor output away. Behind
    /// the same lock, for the same torn-closure-read reason.
    var multiviewFrameHandler: (@Sendable (CVPixelBuffer) -> Void)?

    // LUT (all access on queue)
    let ciContext = CIContext(options: [.cacheIntermediates: false])
    var lutFilter: CIFilter?
    var lutName: String?
    var lutPreview = false
    var lutRecord = false
    var lutIntensity: Double = 1
    let lutBufferPool = PixelBufferPool()
    /// Source input levels ("limited"/"full"; nil — auto by signal type).
    var levelsMode: String?
    /// How the app treats a signal that reports PQ or HLG: `auto` follows the
    /// signal, `off` treats every source as SDR exactly as the app did before
    /// HDR existed (queue-confined, set from the main actor).
    var hdrMode = HDRMode.auto
    /// What the signal last said its codes mean, AFTER `hdrMode` has had its
    /// say — so `off` pins this at `.sdr` and every table, tag and scale
    /// downstream is the one that shipped (queue-confined).
    var signalColorimetry = WireColorimetry.sdr
    /// The colorimetry latched when the current take opened, like the audio
    /// channel mask and the slate: a camera that switches to HDR mid-take must
    /// not retag the SDR frames already in the file.
    var takeColorimetry = WireColorimetry.sdr
    /// 10-bit RGB wire split (display BGRA + precompensated r210 record).
    let tenBitConverter = TenBitConverter()
    /// 12-bit RGB wire split (display BGRA + 64RGBALE record carrying the wire
    /// codes). Held alongside the 10-bit one rather than swapped for it: the
    /// board can change format mid-session and each converter owns pools and a
    /// levels table that are cheap to keep and expensive to rebuild.
    let twelveBitConverter = TwelveBitConverter()
    /// 10-bit YCbCr 4:2:2 wire split (display BGRA + the 'v210' wire frame
    /// itself as the record product). Held for the same reason as the other two,
    /// and it is the cheapest of the three to keep: it owns no record pool,
    /// because the frame the board delivered already is what the encoder wants.
    let tenBitYUVConverter = TenBitYUVConverter()
    /// Bytes per pixel of the buffers currently going to the writer, so the
    /// pre-roll ring's memory cap is sized on what it is really holding —
    /// 12-bit record frames are twice a 10-bit one and would otherwise
    /// overshoot the ring's budget by 2x at UHD (queue-confined).
    var recordBytesPerPixel = 4
    /// Whether the frames the writer is being handed carry the camera's wire
    /// codes rather than display values — decided per frame by the levels stage
    /// and read when a take opens, so the file can state it (queue-confined).
    var recordCarriesWireCodes = false
    /// Scope analysis runs here, never on the capture-critical queue.
    let scopeQueue = DispatchQueue(label: "takeshot.scopes", qos: .utility)
    var scopeBusy = false // pipeline-queue confined
    var scopesEnabled = false
    /// The part of the frame the scopes read — the punched-in crop the viewer
    /// shows (queue-confined, set from the main actor via `setScopeRegion`).
    var scopeRegion = ScopeRegion.full
    /// Frame index of the last pass offered to the analyzer (queue-confined).
    var lastScopeFrame = 0

    // The taught record indicator (see `+VisualRec`): a third REC trigger, which
    // like the scopes runs on a queue of its own with latest-wins coalescing and
    // never on the capture-critical one. The teaching and the latched reading
    // cross under `visualRecLock`, deliberately not the capture queue — the main
    // actor writes them on every slider tick while the operator teaches.
    let visualRecQueue = DispatchQueue(label: "takeshot.recwatch", qos: .utility)
    let visualRecLock = NSLock()
    /// Guarded by `visualRecLock`.
    var storedVisualRec = VisualRecTeaching()
    /// The latest reading, guarded by `visualRecLock`; nil for "no evidence".
    var storedVisualRecReading: VisualRecReading?
    /// Where the latest measured frame sat on the taught axis — the teaching
    /// readout. Guarded by `visualRecLock`.
    var storedVisualRecPosition: (along: Double, residual: Double)?
    var visualRecBusy = false // capture-queue confined
    /// Frame index of the last pass offered to the watcher (queue-confined).
    var lastVisualRecFrame = 0
    /// Whether the trigger is armed, mirrored onto the capture queue once per
    /// stride by `watchVisualRec`. Queue-confined, and it exists so the pre-roll
    /// ring can be sized for the visual confirm's span without taking
    /// `visualRecLock` on every single frame.
    var visualRecArmed = false

    // Pinned reference compare (all access on queue): the reference frame is
    // composited over the live preview with the shared wipe/blend math.
    var previewReference: CVPixelBuffer?
    /// The same pin, taken at the pre-LUT stage. Wipe/blend compare what the
    /// operator SEES (both halves carry the preview LUT), but difference is a
    /// measurement: it reads this copy against the pre-LUT live frame, so an
    /// active viewing LUT cannot bend the numbers (see `presentProcessedFrame`).
    /// Identical to `previewReference` whenever no preview LUT is applied.
    var previewReferencePreLUT: CVPixelBuffer?
    var previewCompare: CompareCompositor.Mode = .off
    let comparePool = PixelBufferPool()

    /// The fitted reference is invariant per (buffer, extent) — rebuilt only
    /// when the pin or the live frame size changes.
    struct FittedReference {
        let source: CVPixelBuffer
        let extent: CGRect
        let image: CIImage
    }

    var fittedReferenceCache: FittedReference?

    // Chroma key (see `+ChromaKey`): a display-stage tool, one stage after the
    // viewing LUT and one before the sinks. The keyer is confined to
    // `displayQueue`; the settings the main actor hands over cross under
    // `chromaLock`, which is deliberately not the capture queue — the whole
    // point of this feature is that it never touches per-frame capture work.
    let chromaKeyer = ChromaKeyer()
    /// The operator aids (see `AssistStage`): the stage AFTER the key, so a
    /// false colour meters the keyed picture the monitor is showing. Confined
    /// to `displayQueue` like the keyer; the settings cross under its own lock.
    public let assistStage = AssistStage()
    let chromaLock = NSLock()
    var storedChromaKey = ChromaKey()
    /// Frames that reached the display queue past their own frame interval and
    /// were shown WITHOUT the key rather than held up (guarded by chromaLock).
    var chromaLateDropCount = 0

    var monitorEnabled = false
    var monitorFormatCache: CMAudioFormatDescription?

    public static let levelsLog = OSLog(subsystem: "com.takeshot.app", category: "levels")

    let queue = DispatchQueue(label: "takeshot.pipeline", qos: .userInitiated)

    // pipeline state — queue only
    var config: Config
    var detector: RecDetector
    var writer: TakeWriter?
    var format: CaptureFormat?
    var frameIndex = 0
    var droppedFrames = 0
    var lastTimecode: Timecode?
    var takeStartTC: Timecode?
    var takeStartedAt = Date()
    /// The slate latched when the take started — like the audio channel mask,
    /// so a scene typed mid-take cannot retag the footage already written.
    var takeSlate = SlateMetadata.empty
    var takeRoll = ""
    var takeNumber = 0
    /// One buffered frame awaiting a possible take start.
    struct PreRollFrame {
        let index: Int
        let pixelBuffer: CVPixelBuffer
        let pts: CMTime
    }

    /// Frames before record start — for pre-roll (only while writer == nil).
    var preRollBuffer: [PreRollFrame] = []
    /// Audio for the same window, kept RAW (the channel mask is latched when the
    /// take starts, so it cannot be applied while buffering). Without this the
    /// pre-roll gave picture with no sound under it: the audio track began where
    /// the operator pressed REC, seconds after the video did.
    var preRollAudio: [(pts: CMTime, buffer: CMSampleBuffer)] = []
    /// Accumulated VANC stats by (DID, SDID).
    var vancStatsDirty = false
    var vancStatsLastPublish = 0
    /// Pending file-finalization tasks (awaited on stop/exit), keyed so each
    /// one can drop itself when it completes.
    var pendingFinishTasks: [Int: Task<Void, Never>] = [:]
    var nextFinishID = 0

    public init(config: Config) {
        self.config = config
        self.detector = RecDetector(config: RecDetectorConfig(
            startDebounceFrames: config.settings.startDebounceFrames,
            stopDebounceFrames: config.settings.stopDebounceFrames,
            vancOnly: config.settings.detectionMode == .vanc))
    }

    // MARK: - ingress backpressure (see +Input)

    let inFlightLock = NSLock()
    var inFlightFrames = 0
    var ingressDrops = 0

    // MARK: - health mirror (see +Health)

    /// Guards `storedHealth`, and nothing else. Deliberately not the capture
    /// queue: the point of the mirror is that "how is the recorder doing" can
    /// be answered without waiting on per-frame work.
    let healthLock = NSLock()
    var storedHealth = PipelineHealth()
    /// The writer's audio-drop tally as last mirrored (queue-confined), so the
    /// session total can be advanced by the delta rather than overwritten.
    var mirroredAudioDrops = 0

    var trimFormatCache: CMAudioFormatDescription?
    var lastPublishedLevels: [Float] = []
    /// Input audio channel count (cached even during preview — so the writer
    /// knows the audio input format up front, before the first record packet).
    var sourceAudioChannels = 0

    // LTC from an embedded audio channel (all access on queue).
    let ltcDecoder = LTCDecoder()
    var latestLTC: Timecode?

    /// How many channels are actually written under the current mask.
    var recordChannelCount: Int {
        guard sourceAudioChannels > 0 else { return 0 }
        guard let mask = config.settings.audioChannelMask else { return sourceAudioChannels }
        return (0..<sourceAudioChannels).filter { mask & (1 << $0) != 0 }.count
    }

    /// The last levels decision written to the log — one line per change (see
    /// +Frame).
    var lastLoggedLevels = ""
    /// Audio channel mask captured at take start (see handleAudio).
    var recordingMask: Int?

    // MARK: - external (USB) audio source — all queue-confined (see +ExternalAudio)

    /// Which source's packets the audio path admits. The inactive source's
    /// packets are discarded whole — the two are never mixed.
    var audioSourceKind: AudioSource = .embedded
    /// Host→stream clock anchor for external audio, taken on the frame path.
    var externalHostAnchor: (host: CMTime, stream: CMTime)?
    /// The external device is known gone; pad the running take with silence.
    var externalAudioLost = false
    /// External packets stopped arriving without a disconnect event — the
    /// starvation watchdog opened the same silence-padding path.
    var externalAudioStarved = false
    /// Stream-time end of the last admitted (or padded) external packet while
    /// a take runs; where the next padding chunk starts.
    var lastExternalAudioEnd: CMTime?
    /// Silence packets written to keep the take's audio continuous after the
    /// external source went away. Per take, reported like dropped audio.
    var gapFilledAudioPackets = 0
    var padFormatCache: CMAudioFormatDescription?
    /// A source switch requested mid-take waits here for the writer to close:
    /// the take's channel count is latched and must not change under it.
    var pendingAudioSourceSwitch: (kind: AudioSource, expectedChannels: Int)?

    // TC-run onset detection for the mid-take timecode re-anchor.
    var lastWireTimecode: Timecode?
    var frozenTCStreak = 0

    var frameGrabHandler: (@Sendable (Data?) -> Void)?

    // raw packet snapshots; the hex dump is built only at publish time —
    // formatting per packet per frame was thousands of string allocs a second
    struct RawVancStat {
        var did: UInt8
        var sdid: UInt8
        var count: Int
        var lastLine: UInt32
        var lastData: Data
    }

    var rawVancStats: [String: RawVancStat] = [:]

    /// Free URL: if the file exists, adds _2, _3… before the extension.
    /// (Used by beginTake; `recStartIndex` there is the camera's actual record
    /// start frame from the detector, nil for manual start.)
    /// Names handed out but whose files do not exist yet. AVAssetWriter creates
    /// the file only at startWriting, so two pipelines starting on the same REC
    /// event — multicam with a template that carries no {cam} token — both saw
    /// the path free and both claimed it. The reservation closes that window.
    static let reservationLock = NSLock()
    /// Guarded by reservationLock — the annotation states that contract, the
    /// same way the zebra cube cache does in MetalPreviewLayer.
    nonisolated(unsafe) static var reservedPaths: Set<String> = []

    /// How many frames a take must lose before the sticky alarm fires. One
    /// isolated drop at take start is normal encoder back-pressure; sustained
    /// loss is not.
    static let droppedFrameAlarmThreshold = 5

    /// Scope passes per second the frame path aims for while a scope surface is
    /// open. A waveform is read as a moving picture — below ~10 Hz it reads as
    /// stepping — and above ~15 the operator cannot tell, so this is where the
    /// CPU stops being spent. The busy gate keeps the real rate at or under it.
    static let scopeUpdatesPerSecond = 15.0

    /// Frames between the passes the frame path OFFERS the analyzer, at a given
    /// signal rate. The delivered rate is `frameRate / stride` — 12.5 Hz at
    /// 25 fps, 15 at 30 and 60 — as long as a pass finishes inside one stride
    /// interval; past that the busy gate starts dropping and the operator sees
    /// the trace step. Extracted so the arithmetic can be asserted without a
    /// stopwatch: the wall-clock half of the measurement belongs on a machine
    /// that is not also building something.
    static func scopeStride(atFrameRate frameRate: Double) -> Int {
        max(1, Int((frameRate / scopeUpdatesPerSecond).rounded()))
    }

    /// Suffix that marks a take whose finalize failed. Renaming is best-effort:
    /// if it does not work the original path is returned and the operator still
    /// gets the alarm.
    ///
    /// Public because the app layer has to RECOGNISE the marker as well as
    /// write it — the diagnostic bundle flags such a take explicitly instead of
    /// leaving the reader to notice a substring in a file name.
    public static let failedTakeSuffix = "_FAILED"

    let latestPreviewLock = NSLock()
    var latestPreview: CVPixelBuffer?
    /// The same frame BEFORE the preview LUT (the leveled display buffer) —
    /// what the difference compare measures on, and what a pin taken while a
    /// LUT is active stores as its pre-LUT copy. The very same buffer as
    /// `latestPreview` while no preview LUT is applied.
    var latestPreLUT: CVPixelBuffer?

    // Presentation runs on its own queue with latest-wins coalescing:
    // MetalPreviewLayer.present renders + waits on the GPU and nextDrawable()
    // can park for a vsync when the window is occluded — none of that may
    // stall the capture-critical queue.
    let displayQueue = DispatchQueue(label: "takeshot.display",
                                             qos: .userInteractive)
    let presentLock = NSLock()
    var pendingPresent: CVPixelBuffer?
    /// The same frame before the operator's on-screen compositing — what the
    /// camera grid is fed. Carried alongside `pendingPresent` rather than
    /// pulled from `latestPreview` inside the hop so the grid and the viewer
    /// are looking at one frame, not at two a moment apart.
    var pendingClean: CVPixelBuffer?
    var presentScheduled = false
    /// When the pending frame stops being worth extra work, in uptime
    /// nanoseconds: one frame interval after it was handed over. The display
    /// stage drops the chroma key on a frame that is already past it rather
    /// than dropping the frame (see `chromaKeyed`).
    var pendingDeadline: UInt64 = 0
    /// The last frame handed to the display stage, BEFORE the key and the aids
    /// were drawn on it. Display-queue confined; kept so that switching an aid
    /// on while the signal is paused (or gone) re-decorates what is on screen
    /// instead of waiting for a frame that is not coming.
    var lastDisplaySource: CVPixelBuffer?

}
