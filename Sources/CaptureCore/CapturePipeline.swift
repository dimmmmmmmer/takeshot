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
        public var scene: String
        public var roll: String
        public var takeNumber: Int

        public init(settings: CaptureSettings, scene: String = "",
                    roll: String = "", takeNumber: Int) {
            self.settings = settings
            self.scene = scene
            self.roll = roll
            self.takeNumber = takeNumber
        }
    }

    // UI callbacks, invoked on the main queue
    public var onFormatChanged: ((CaptureFormat?) -> Void)?
    public var onTimecode: ((Timecode?) -> Void)?
    public var onRecStateChanged: ((Bool) -> Void)?
    public var onSignal: ((Bool) -> Void)?

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
    private var storedOnError: ((String) -> Void)?

    public var onTakeFinished: ((Take) -> Void)? {
        get { takeCallbackLock.withLock { storedOnTakeFinished } }
        set { takeCallbackLock.withLock { storedOnTakeFinished = newValue } }
    }

    public var onError: ((String) -> Void)? {
        get { takeCallbackLock.withLock { storedOnError } }
        set { takeCallbackLock.withLock { storedOnError = newValue } }
    }
    /// VANC packet stats (for the monitor); sent about once a second on changes.
    public var onVancStats: (([VancPacketStat]) -> Void)?
    /// Per-channel audio peak levels, dBFS. Arrive at the audio-packet rate (~25 Hz).
    public var onAudioLevels: (([Float]) -> Void)?
    /// Scope data (waveform + histograms) from the displayed frame, ~8 Hz while
    /// enabled via setScopesEnabled. Delivered on the main queue.
    public var onScopeData: ((ScopeData) -> Void)?
    /// Stereo monitor feed (first two enabled channels) while audio monitoring
    /// is on. Delivered on the pipeline queue — the consumer re-queues itself.
    public var onMonitorAudio: ((CMSampleBuffer) -> Void)?

    /// The two callbacks a finalizing take needs, snapshotted so the detached
    /// finish task can hand results to the main queue without sending the
    /// pipeline itself across isolation.
    struct TakeReport: @unchecked Sendable {
        let finished: (Take) -> Void
        let failed: (String) -> Void
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
    /// 10-bit RGB wire split (display BGRA + precompensated r210 record).
    let tenBitConverter = TenBitConverter()
    /// Scope analysis runs here, never on the capture-critical queue.
    let scopeQueue = DispatchQueue(label: "takeshot.scopes", qos: .utility)
    var scopeBusy = false // pipeline-queue confined
    var scopesEnabled = false

    // Pinned reference compare (all access on queue): the reference frame is
    // composited over the live preview with the shared wipe/blend math.
    var previewReference: CVPixelBuffer?
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
    var takeScene = ""
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

    /// Suffix that marks a take whose finalize failed. Renaming is best-effort:
    /// if it does not work the original path is returned and the operator still
    /// gets the alarm.
    static let failedTakeSuffix = "_FAILED"

    /// Expansion table 16-235 → 0-255 for limited-range RGB inputs. Defined on
    /// gamma-encoded code values, so it must run on raw bytes — a CIColorMatrix
    /// in CI's linear working space crushes shadows and dulls highlights.
    static let levelsExpandTable: [UInt8] = (0...255).map {
        UInt8(min(255, max(0, Int((Double($0) - 16) * 255 / 219 + 0.5))))
    }
    static let levelsTableIdentity: [UInt8] = (0...255).map { UInt8($0) }

    let latestPreviewLock = NSLock()
    var latestPreview: CVPixelBuffer?

    // Presentation runs on its own queue with latest-wins coalescing:
    // MetalPreviewLayer.present renders + waits on the GPU and nextDrawable()
    // can park for a vsync when the window is occluded — none of that may
    // stall the capture-critical queue.
    let displayQueue = DispatchQueue(label: "takeshot.display",
                                             qos: .userInteractive)
    let presentLock = NSLock()
    var pendingPresent: CVPixelBuffer?
    var presentScheduled = false

}
