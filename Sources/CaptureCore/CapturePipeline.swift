@preconcurrency import Accelerate
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
    public var onTakeFinished: ((Take) -> Void)?
    public var onSignal: ((Bool) -> Void)?
    public var onError: ((String) -> Void)?
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

    var takeReport: TakeReport {
        TakeReport(finished: { [onTakeFinished] in onTakeFinished?($0) },
                   failed: { [onError] in onError?($0) })
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
    private var lutPreview = false
    var lutRecord = false
    var lutIntensity: Double = 1
    let lutBufferPool = PixelBufferPool()
    /// Source input levels ("limited"/"full"; nil — auto by signal type).
    private var levelsMode: String?
    /// 10-bit RGB wire split (display BGRA + precompensated r210 record).
    private let tenBitConverter = TenBitConverter()
    /// Scope analysis runs here, never on the capture-critical queue.
    private let scopeQueue = DispatchQueue(label: "takeshot.scopes", qos: .utility)
    private var scopeBusy = false // pipeline-queue confined

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

    /// Input levels of the source signal: nil/"auto" — guess from the signal
    /// (RGB 4:4:4 → limited), "limited" (16-235) — expand once to full,
    /// "full" (0-255) — pass through (legacy "off" means the same).
    public func setVideoLevels(_ mode: String?) {
        queue.async {
            switch mode {
            case "auto", nil: self.levelsMode = nil
            case "off": self.levelsMode = "full" // legacy value: pass through
            default: self.levelsMode = mode
            }
        }
    }

    /// Set the LUT (nil — off), apply modes, and intensity (0…1).
    public func setLUT(_ lut: CubeLUT?, preview: Bool, record: Bool,
                       intensity: Double = 1) {
        queue.async {
            self.lutFilter = lut?.makeFilter()
            self.lutName = lut?.name
            self.lutPreview = preview && lut != nil
            self.lutRecord = record && lut != nil
            self.lutIntensity = min(1, max(0, intensity))
            self.lutBufferPool.reset()
        }
    }

    /// Intensity only — no filter rebuild (for the slider: reacts to every tick
    /// without parsing the .cube and without disk operations).
    public func setLUTIntensity(_ intensity: Double) {
        queue.async { self.lutIntensity = min(1, max(0, intensity)) }
    }

    private var scopesEnabled = false

    /// Toggle scope analysis (skipped entirely while off — zero cost).
    public func setScopesEnabled(_ on: Bool) {
        queue.async {
            self.scopesEnabled = on
            // analyze the current frame right away — the scopes window should
            // open with data, not "waiting for signal"
            if on, let buffer = self.currentPreviewBuffer(),
               let scopeData = ScopeAnalyzer.analyze(buffer) {
                DispatchQueue.main.async { self.onScopeData?(scopeData) }
            }
        }
    }

    var monitorEnabled = false
    var monitorFormatCache: CMAudioFormatDescription?

    public static let levelsLog = OSLog(subsystem: "com.takeshot.app", category: "levels")

    let queue = DispatchQueue(label: "takeshot.pipeline", qos: .userInitiated)

    // pipeline state — queue only
    var config: Config
    private var detector: RecDetector
    var writer: TakeWriter?
    var format: CaptureFormat?
    var frameIndex = 0
    var droppedFrames = 0
    private var lastTimecode: Timecode?
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
    private var vancStatsDirty = false
    private var vancStatsLastPublish = 0
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

    // MARK: - control (from MainActor)

    public func update(config: Config) {
        queue.async {
            let detectorChanged =
                config.settings.startDebounceFrames != self.config.settings.startDebounceFrames
                || config.settings.stopDebounceFrames != self.config.settings.stopDebounceFrames
                || config.settings.detectionMode != self.config.settings.detectionMode
            if config.settings.audioChannelMask
                != self.config.settings.audioChannelMask {
                // the packed-buffer format caches describe the OLD channel
                // count — reusing them mis-interleaves audio after a change
                self.trimFormatCache = nil
                self.monitorFormatCache = nil
            }
            self.config = config
            if detectorChanged {
                self.detector = RecDetector(config: RecDetectorConfig(
                    startDebounceFrames: config.settings.startDebounceFrames,
                    stopDebounceFrames: config.settings.stopDebounceFrames,
                    vancOnly: config.settings.detectionMode == .vanc))
            }
        }
    }

    /// Manual record start/stop (button).
    public func toggleManualRecord() {
        queue.async {
            if self.writer != nil {
                self.finishTake()
            } else {
                self.beginTake(timecode: self.lastTimecode)
            }
        }
    }

    /// Capture stopped: close the current take, reset state.
    public func captureStopped() {
        queue.async {
            if self.writer != nil {
                self.finishTake()
            }
            self.detector.reset()
            self.format = nil
            self.lastTimecode = nil
            self.latestLTC = nil // the old session's LTC must not name new takes
            self.ltcDecoder.reset()
            self.frameGrabHandler = nil
            self.preRollBuffer.removeAll()
            self.preRollAudio.removeAll()
            self.latestPreviewLock.lock()
            self.latestPreview = nil // don't compare against a frozen frame
            self.latestPreviewLock.unlock()
            self.rawVancStats.removeAll()
            self.vancStatsLastPublish = 0
            DispatchQueue.main.async {
                self.onFormatChanged?(nil)
                self.onTimecode?(nil)
                self.onVancStats?([])
                self.onAudioLevels?([])
            }
        }
    }

    // MARK: - backend input (capture threads)

    public func handleFormat(_ newFormat: CaptureFormat) {
        queue.async {
            // a re-announced identical format must not reset detection state:
            // it would wipe the pre-roll buffer and restart REC debounce mid-take
            guard newFormat != self.format else { return }
            // a REAL format change restarts the streams (PTS timeline resets),
            // so an open take would silently starve while REC stayed red —
            // close it cleanly and tell the operator
            if self.writer != nil {
                self.finishTake()
                DispatchQueue.main.async {
                    self.onError?("Take closed: input format changed mid-take")
                }
            }
            self.format = newFormat
            self.detector.reset()
            self.preRollBuffer.removeAll()
            self.preRollAudio.removeAll()
            DispatchQueue.main.async { self.onFormatChanged?(newFormat) }
        }
    }

    public func handleSignal(present: Bool) {
        // called from the DeckLink callback inside its @synchronized region —
        // clearToBlack does GPU work (nextDrawable can park ~1 s occluded),
        // so everything hops to our own queues
        queue.async {
            if !present {
                // The cable is out or the camera stopped feeding: no frames means
                // no VANC, so the camera's stop AND its next start are both
                // invisible to the detector. Left open, the writer would swallow
                // the next take into the same file — one clip holding the tail of
                // take 12, a gap, and take 13, with a clip counter that advanced
                // once. Close on the spot; a re-lock starts a fresh take.
                if self.writer != nil {
                    self.finishTake()
                    DispatchQueue.main.async {
                        self.onError?("Take closed: input signal lost mid-take")
                    }
                }
                self.detector.reset()
                // frames buffered before the dropout are separated from whatever
                // comes back by the length of the dropout — as pre-roll they
                // would open the next take with stale frames and a PTS gap
                self.preRollBuffer.removeAll()
                self.preRollAudio.removeAll()
                // no stale frame for later sink registrations or the compare
                self.latestPreviewLock.lock()
                self.latestPreview = nil
                self.latestPreviewLock.unlock()
                self.displayQueue.async {
                    self.displaySinks.clearToBlack()
                }
            }
            DispatchQueue.main.async { self.onSignal?(present) }
        }
    }

    private let inFlightLock = NSLock()
    private var inFlightFrames = 0
    private var ingressDrops = 0

    /// What the backends deliver.
    public func handleFrame(_ frame: CapturedFrame) {
        handleFrame(pixelBuffer: frame.pixelBuffer, pts: frame.pts,
                    timecode: frame.timecode, vancTrigger: frame.vancTrigger,
                    ancillaryPackets: frame.ancillaryPackets)
    }

    public func handleFrame(pixelBuffer: CVPixelBuffer, pts: CMTime,
                            timecode rawTimecode: Timecode?,
                            vancTrigger: VancTrigger? = nil,
                            ancillaryPackets: [AncillaryPacket] = []) {
        // backpressure: a stalled destination (NAS waking up) piles retained
        // UHD buffers into the queue — drop at ingress past a small window
        inFlightLock.lock()
        if inFlightFrames >= 12 {
            ingressDrops += 1
            let drops = ingressDrops
            inFlightLock.unlock()
            if drops == 1 || drops % 100 == 0 {
                DispatchQueue.main.async {
                    self.onError?("Pipeline overloaded — \(drops) frame(s) "
                        + "dropped at ingress")
                }
            }
            return
        }
        inFlightFrames += 1
        inFlightLock.unlock()
        queue.async {
            defer {
                self.inFlightLock.lock()
                self.inFlightFrames -= 1
                self.inFlightLock.unlock()
            }
            self.processFrame(pixelBuffer: pixelBuffer, pts: pts,
                              timecode: rawTimecode, vancTrigger: vancTrigger,
                              ancillaryPackets: ancillaryPackets)
        }
    }

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

    // MARK: - processing (on queue)

    private func processFrame(pixelBuffer: CVPixelBuffer, pts: CMTime,
                              timecode rawTimecode: Timecode?, vancTrigger: VancTrigger?,
                              ancillaryPackets: [AncillaryPacket]) {
        guard let format else { return }
        tagColorIfUntagged(pixelBuffer)
        frameIndex += 1
        updateVancStats(ancillaryPackets)
        let vancTrigger = vancTrigger ?? VancParser.recTrigger(in: ancillaryPackets)

        // the bridge may not know the timecode fps — fill it from the format
        var timecode = rawTimecode
        if var tc = timecode, tc.fps <= 0 {
            tc.fps = format.timecodeFPS
            timecode = tc
        }
        // LTC replaces RP188 wholesale when selected (detector, UI, TC track)
        if config.settings.timecodeSource == "ltc" {
            timecode = latestLTC
        }
        lastTimecode = timecode

        // input levels: the setting states what the SOURCE carries on the wire.
        // "limited" (16-235 RGB) is expanded once to the full-range BGRA the
        // rest of the pipeline assumes; "full" passes through untouched (e.g.
        // a playout device already set to Full output levels). auto (nil)
        // assumes limited for RGB 4:4:4 HDMI (CTA-861 default). Conversion to
        // legal-range YUV in the recorded file is the encoder's job — never
        // done on pixels here, so it can't be applied twice.
        let inputLevels = levelsMode ?? (format.isRGB444 ? "limited" : nil)
        // one log line per decision change — settles "is expansion active" without
        // guessing (a stale-settings app instance once recorded an unexpanded take)
        if lastLoggedLevels != (inputLevels ?? "passthrough") {
            lastLoggedLevels = inputLevels ?? "passthrough"
            os_log("levels: mode=%{public}s rgb444=%{public}d effective=%{public}s",
                   log: Self.levelsLog, type: .default,
                   levelsMode ?? "auto", format.isRGB444 ? 1 : 0,
                   inputLevels ?? "passthrough")
        }
        // 10-bit RGB wire ('r210'): one pass yields the full-range display
        // BGRA AND the precompensated 10-bit record buffer; levels are applied
        // inside the converter, so the 8-bit stage below must not run again
        var tenBitRecord: CVPixelBuffer?
        let leveled: CVPixelBuffer
        if CVPixelBufferGetPixelFormatType(pixelBuffer) == TenBitConverter.r210 {
            tenBitConverter.setLimitedRange(inputLevels != "full")
            guard let split = tenBitConverter.convert(pixelBuffer) else { return }
            tagColorIfUntagged(split.display)
            leveled = split.display
            tenBitRecord = split.record
        } else {
            leveled = inputLevels == "limited"
                ? (expandLimitedRGB(pixelBuffer) ?? pixelBuffer)
                : pixelBuffer
        }

        // while not recording — accumulate frames into the pre-roll buffer (current
        // frame included): when a take starts, frames from the camera's actual record
        // start (lost to debounce) plus the configured lead seconds are pulled from it.
        // buffered AFTER the levels stage — otherwise a take starts with raw
        // pre-roll frames and jumps in contrast when live leveled frames follow
        if writer == nil {
            // the pre-roll must hold what the WRITER gets: 10-bit when active,
            // but BGRA when a LUT is baked into the recording — beginTake runs
            // applyLUT over these frames and CoreImage cannot read r210
            let preRollFrameBuffer = lutRecord ? leveled : (tenBitRecord ?? leveled)
            preRollBuffer.append(PreRollFrame(index: frameIndex,
                                              pixelBuffer: preRollFrameBuffer,
                                              pts: pts))
            let capacity = preRollCapacity
            if preRollBuffer.count > capacity {
                preRollBuffer.removeFirst(preRollBuffer.count - capacity)
            }
        }

        // LUT: preview may have the LUT while recording stays clean (or vice versa)
        let displayBuffer = lutPreview
            ? (applyLUT(to: leveled) ?? leveled) : leveled
        // LUT baking is an 8-bit creative decision — it keeps the BGRA record
        // path; otherwise the 10-bit record buffer goes to the writer verbatim
        let recordBuffer = lutRecord
            ? (lutPreview ? displayBuffer : (applyLUT(to: leveled) ?? leveled))
            : (tenBitRecord ?? leveled)

        var startedThisFrame = false
        let mode = config.settings.detectionMode
        if mode != .manual {
            // .vanc is enforced inside the detector (vancOnly): TC is passed
            // through so the take still records its start timecode
            let sample = FrameSample(
                index: frameIndex,
                timecode: timecode,
                vancTrigger: (mode == .auto || mode == .vanc) ? vancTrigger : nil)
            if let event = detector.process(sample) {
                switch event {
                case .started(let atIndex, let startTC):
                    beginTake(timecode: startTC ?? timecode, recStartIndex: atIndex)
                    startedThisFrame = true // current frame already written from the buffer
                case .stopped:
                    finishTake()
                }
            }
        }

        // Rec Run started AFTER the take: while the camera TC stands still the
        // file's TC track keeps counting, so the overlap would drift by the
        // frozen duration. Re-anchor the track the moment the TC starts moving.
        if let writer, let tc = timecode {
            if let previous = lastWireTimecode {
                if tc.frameNumber == previous.frameNumber {
                    frozenTCStreak += 1
                } else {
                    if frozenTCStreak >= 3 {
                        writer.addTimecodeResync(timecode: tc, at: pts)
                        os_log("TC resync mid-take: %{public}s (frozen %d frames)",
                               log: Self.levelsLog, type: .default,
                               tc.description, frozenTCStreak)
                    }
                    frozenTCStreak = 0
                }
            }
            lastWireTimecode = tc
        } else if writer == nil {
            lastWireTimecode = timecode
            frozenTCStreak = 0
        }

        if !startedThisFrame, let writer,
           !writer.append(pixelBuffer: recordBuffer, pts: pts) {
            if writer.hasFailed {
                // permanent: the volume went away, the disk filled, the encoder
                // died. Counting drops here would keep REC red for the rest of
                // the take while nothing at all reaches the file.
                let reason = writer.failureReason
                finishTake() // clears the writer, so this branch fires once
                DispatchQueue.main.async {
                    self.onError?("TAKE LOST — recording stopped, writer failed: \(reason)")
                }
            } else {
                droppedFrames += 1
                // The encoder is still swallowing the pre-roll burst when the
                // first live frame arrives, so virtually every take drops one
                // frame. Alarming on that trains the operator to ignore the
                // banner — which is the one thing a real disk failure needs.
                // Sustained loss still alarms, and the take's total is reported
                // when it closes either way.
                if droppedFrames == Self.droppedFrameAlarmThreshold
                    || droppedFrames % 100 == 0 {
                    let count = droppedFrames
                    DispatchQueue.main.async {
                        self.onError?("Dropped \(count) recording frame(s) "
                            + "— encoder/disk can't keep up")
                    }
                }
            }
        }

        // scopes: analyzed OFF the pipeline queue (content-dependent cost —
        // noisy frames measured two orders slower than flat ones); if the
        // previous pass is still running the frame is simply skipped
        if scopesEnabled, frameIndex % 3 == 0, !scopeBusy {
            scopeBusy = true
            let frame = displayBuffer // retained: the pool won't recycle it
            scopeQueue.async { [weak self] in
                let data = ScopeAnalyzer.analyze(frame)
                guard let pipeline = self else { return }
                pipeline.queue.async { pipeline.scopeBusy = false }
                if let data {
                    let report = pipeline.onScopeData
                    DispatchQueue.main.async { report?(data) }
                }
            }
        }

        // one-shot frame grab: stills are deliverables like the recording — the
        // preview LUT is never baked in, only a look that is being recorded
        if let grab = frameGrabHandler {
            frameGrabHandler = nil
            // the clean 8-bit frame: CI can't read r210, and the record look
            // without a baked LUT IS the leveled frame
            let png = Self.pngData(from: lutRecord ? recordBuffer : leveled,
                                   ciContext: ciContext)
            DispatchQueue.main.async { grab(png) }
        }

        // pinned reference compare — on screen only (scopes/stills/the
        // compare-provider frame stay clean)
        var screenBuffer = displayBuffer
        if let reference = previewReference {
            if case .off = previewCompare {} else {
                screenBuffer = compositeReference(reference, over: displayBuffer)
                    ?? displayBuffer
            }
        }
        enqueuePreview(pixelBuffer: displayBuffer, screen: screenBuffer)
        DispatchQueue.main.async { self.onTimecode?(timecode) }
    }

    private var lastLoggedLevels = ""
    /// Audio channel mask captured at take start (see handleAudio).
    var recordingMask: Int?

    // TC-run onset detection for the mid-take timecode re-anchor.
    private var lastWireTimecode: Timecode?
    private var frozenTCStreak = 0

    var frameGrabHandler: (@Sendable (Data?) -> Void)?

    // raw packet snapshots; the hex dump is built only at publish time —
    // formatting per packet per frame was thousands of string allocs a second
    private struct RawVancStat {
        var did: UInt8
        var sdid: UInt8
        var count: Int
        var lastLine: UInt32
        var lastData: Data
    }
    private var rawVancStats: [String: RawVancStat] = [:]

    private func updateVancStats(_ packets: [AncillaryPacket]) {
        for packet in packets {
            let key = String(format: "%02X/%02X", packet.did, packet.sdid)
            let previous = rawVancStats[key]
            rawVancStats[key] = RawVancStat(
                did: packet.did, sdid: packet.sdid,
                count: (previous?.count ?? 0) + 1,
                lastLine: packet.lineNumber,
                lastData: Data(packet.data.prefix(24)))
            vancStatsDirty = true
        }
        // publish at most ~once a second so we don't poke the UI every frame
        let interval = Int(format?.frameRate.rounded() ?? 25)
        if vancStatsDirty, frameIndex - vancStatsLastPublish >= interval {
            vancStatsDirty = false
            vancStatsLastPublish = frameIndex
            let stats = rawVancStats.values.map { raw in
                VancPacketStat(
                    did: raw.did, sdid: raw.sdid, count: raw.count,
                    lastLine: raw.lastLine,
                    lastDataHex: raw.lastData
                        .map { String(format: "%02X", $0) }
                        .joined(separator: " "))
            }.sorted { $0.key < $1.key }
            DispatchQueue.main.async { self.onVancStats?(stats) }
        }
    }

    /// Pre-roll frame count (a direct frames setting, fps-independent).
    var preRollFrames: Int {
        config.settings.preRollFramesEffective
    }

    /// Buffer capacity: pre-roll + detection latency + slack, but with a memory
    /// cap. Without the cap, 3 s of pre-roll at 4K60 holds ~6 GB of uncompressed
    /// frames in RAM (OOM); at high resolution the pre-roll quietly shortens.
    private var preRollCapacity: Int {
        let wanted = preRollFrames + config.settings.startDebounceFrames + 3
        guard let format, format.width > 0, format.height > 0 else { return wanted }
        let bytesPerFrame = format.width * format.height * 4
        let budgetBytes = 1_500_000_000 // ~1.5 GB
        let byteCap = max(config.settings.startDebounceFrames + 5,
                          budgetBytes / max(1, bytesPerFrame))
        return min(wanted, byteCap)
    }

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
