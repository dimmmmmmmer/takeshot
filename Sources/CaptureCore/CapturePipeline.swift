import Accelerate
import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import os.log

/// Frame pipeline: takes backend callbacks (from capture threads), runs them
/// through RecDetector, writes takes via TakeWriter, and feeds preview. All work
/// happens on its own serial queue; only UI events hop to the MainActor.
///
/// @unchecked Sendable: all mutable state is touched only on `queue`; UI callbacks
/// are assigned once before capture starts and invoked on main.
public final class CapturePipeline: @unchecked Sendable {
    public struct Config {
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

    /// Live preview sinks: every SwiftUI mount registers its OWN layer (a
    /// CALayer can be hosted by only one NSView; see PreviewSinkRegistry).
    public let displaySinks = PreviewSinkRegistry()
    /// Every displayed frame, on the display queue — hardware playout mirror.
    /// Re-routed from the main actor on every record/playback switch while the
    /// display queue is calling it, so it goes through a lock: a plain closure
    /// property is a two-word value with an ARC-managed context, and a torn
    /// read releases the box under the reader's feet.
    private let displayFrameLock = NSLock()
    private var displayFrameHandler: (@Sendable (CVPixelBuffer) -> Void)?

    public func setOnDisplayFrame(_ handler: (@Sendable (CVPixelBuffer) -> Void)?) {
        displayFrameLock.lock()
        displayFrameHandler = handler
        displayFrameLock.unlock()
    }

    public func addDisplaySink(_ layer: MetalPreviewLayer) {
        displaySinks.add(layer)
        // show the current frame right away — a paused/idle signal won't push
        // one; with no signal, blank the surface instead of letting the frame
        // of the previous source (playback) stick around
        if let buffer = currentPreviewBuffer() {
            layer.present(buffer)
        } else {
            layer.clearToBlack()
        }
    }

    public func removeDisplaySink(_ layer: MetalPreviewLayer) {
        displaySinks.remove(layer)
    }

    public func setViewAssist(_ assist: ViewAssist) {
        displaySinks.setAssist(assist)
    }

    public func setPreviewLetterbox(_ color: CIColor) {
        displaySinks.setLetterbox(color)
    }
    // LUT (all access on queue)
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var lutFilter: CIFilter?
    private var lutName: String?
    private var lutPreview = false
    private var lutRecord = false
    private var lutIntensity: Double = 1
    private let lutBufferPool = PixelBufferPool()
    /// Source input levels ("limited"/"full"; nil — auto by signal type).
    private var levelsMode: String?
    /// 10-bit RGB wire split (display BGRA + precompensated r210 record).
    private let tenBitConverter = TenBitConverter()
    /// Scope analysis runs here, never on the capture-critical queue.
    private let scopeQueue = DispatchQueue(label: "takeshot.scopes", qos: .utility)
    private var scopeBusy = false // pipeline-queue confined

    // Pinned reference compare (all access on queue): the reference frame is
    // composited over the live preview with the shared wipe/blend math.
    private var previewReference: CVPixelBuffer?
    private var previewCompare: CompareCompositor.Mode = .off
    private let comparePool = PixelBufferPool()

    /// Pin an already-decoded frame (deep copy — pooled buffers get reused).
    public func setPreviewReference(buffer: CVPixelBuffer?) {
        queue.async {
            self.previewReference = buffer.flatMap { self.deepCopy($0) }
        }
    }

    /// Pin the current live frame.
    public func pinReferenceFromCurrentFrame() {
        queue.async {
            guard let current = self.currentPreviewBuffer() else { return }
            self.previewReference = self.deepCopy(current)
        }
    }

    public func setPreviewCompare(_ mode: CompareCompositor.Mode) {
        queue.async {
            self.previewCompare = mode
        }
    }

    private func deepCopy(_ buffer: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let image = CIImage(cvPixelBuffer: buffer,
                            options: [.colorSpace: NSNull()])
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var copy: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_32BGRA,
                            attrs as CFDictionary, &copy)
        guard let copy else { return nil }
        let destination = CIRenderDestination(pixelBuffer: copy)
        destination.colorSpace = nil
        guard let task = try? ciContext.startTask(toRender: image,
                                                  to: destination)
        else { return nil }
        _ = try? task.waitUntilCompleted()
        return copy
    }

    /// The fitted reference is invariant per (buffer, extent) — rebuilt only
    /// when the pin or the live frame size changes.
    private struct FittedReference {
        let source: CVPixelBuffer
        let extent: CGRect
        let image: CIImage
    }

    private var fittedReferenceCache: FittedReference?

    /// Reference (front, left/top of the wipe) over the live frame.
    private func compositeReference(_ reference: CVPixelBuffer,
                                    over live: CVPixelBuffer) -> CVPixelBuffer? {
        let back = CIImage(cvPixelBuffer: live, options: [.colorSpace: NSNull()])
        let front: CIImage
        if let cache = fittedReferenceCache, cache.source === reference,
           cache.extent == back.extent {
            front = cache.image
        } else {
            front = CompareCompositor.fitted(
                CIImage(cvPixelBuffer: reference, options: [.colorSpace: NSNull()]),
                into: back.extent)
            fittedReferenceCache = FittedReference(
                source: reference, extent: back.extent, image: front)
        }
        let result = CompareCompositor.compose(front: front, back: back,
                                               mode: previewCompare)
        let width = Int(back.extent.width.rounded())
        let height = Int(back.extent.height.rounded())
        guard width > 0, height > 0,
              let out = comparePool.buffer(width: width, height: height)
        else { return nil }
        let destination = CIRenderDestination(pixelBuffer: out)
        destination.colorSpace = nil
        guard let task = try? ciContext.startTask(toRender: result,
                                                  to: destination)
        else { return nil }
        _ = try? task.waitUntilCompleted()
        return out
    }

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

    private var monitorEnabled = false
    private var monitorFormatCache: CMAudioFormatDescription?

    /// Toggle the live audio monitor feed (onMonitorAudio).
    public func setAudioMonitorEnabled(_ on: Bool) {
        queue.async { self.monitorEnabled = on }
    }

    public static let levelsLog = OSLog(subsystem: "com.takeshot.app", category: "levels")

    private let queue = DispatchQueue(label: "takeshot.pipeline", qos: .userInitiated)

    // pipeline state — queue only
    private var config: Config
    private var detector: RecDetector
    private var writer: TakeWriter?
    private var format: CaptureFormat?
    private var frameIndex = 0
    private var droppedFrames = 0
    private var lastTimecode: Timecode?
    private var takeStartTC: Timecode?
    private var takeStartedAt = Date()
    private var takeScene = ""
    private var takeRoll = ""
    private var takeNumber = 0
    /// One buffered frame awaiting a possible take start.
    private struct PreRollFrame {
        let index: Int
        let pixelBuffer: CVPixelBuffer
        let pts: CMTime
    }

    /// Frames before record start — for pre-roll (only while writer == nil).
    private var preRollBuffer: [PreRollFrame] = []
    /// Audio for the same window, kept RAW (the channel mask is latched when the
    /// take starts, so it cannot be applied while buffering). Without this the
    /// pre-roll gave picture with no sound under it: the audio track began where
    /// the operator pressed REC, seconds after the video did.
    private var preRollAudio: [(pts: CMTime, buffer: CMSampleBuffer)] = []
    /// Accumulated VANC stats by (DID, SDID).
    private var vancStatsDirty = false
    private var vancStatsLastPublish = 0
    /// Pending file-finalization tasks (awaited on stop/exit), keyed so each
    /// one can drop itself when it completes.
    private var pendingFinishTasks: [Int: Task<Void, Never>] = [:]
    private var nextFinishID = 0

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

    private var trimFormatCache: CMAudioFormatDescription?
    private var lastPublishedLevels: [Float] = []
    /// Input audio channel count (cached even during preview — so the writer
    /// knows the audio input format up front, before the first record packet).
    private var sourceAudioChannels = 0

    /// What the backend says its audio input is configured for, before any
    /// packet has arrived. A take can start on capture frame 1 (a VANC trigger
    /// fires with no debounce), and without this the writer got no audio input
    /// at all and every packet of that take was discarded in silence. The first
    /// real packet still wins — this is only the head start.
    public func setExpectedAudioChannels(_ count: Int) {
        queue.async {
            guard count > 0, self.sourceAudioChannels == 0 else { return }
            self.sourceAudioChannels = count
        }
    }

    public func handleAudio(_ sampleBuffer: CMSampleBuffer) {
        queue.async {
            let levels = PCMAudio.peakLevels(of: sampleBuffer)
            self.sourceAudioChannels = levels.count
            if self.config.settings.timecodeSource == "ltc" {
                self.decodeLTC(from: sampleBuffer, channels: levels.count)
            }
            // meters show ALL channels; only channels enabled in the mask are written
            var toWrite: CMSampleBuffer? = sampleBuffer
            // the mask is LATCHED for the take: the writer's channel count is
            // fixed at start, a live change would kill the whole file
            let activeMask = self.writer != nil
                ? self.recordingMask : self.config.settings.audioChannelMask
            if let mask = activeMask {
                let indices = (0..<32).filter { mask & (1 << $0) != 0 }
                toWrite = PCMAudio.selectChannels(sampleBuffer, indices: indices,
                                                  formatCache: &self.trimFormatCache)
            }
            if let writer = self.writer {
                if let toWrite { writer.append(audioSampleBuffer: toWrite) }
            } else if self.preRollFrames > 0 {
                // not recording: keep the sound of the pre-roll window, so the
                // take that starts in a moment has audio under its first frames
                self.bufferPreRollAudio(sampleBuffer)
            }
            // monitor: the first two ENABLED channels as a stereo feed
            if self.monitorEnabled, let onMonitorAudio = self.onMonitorAudio {
                let indices: [Int]
                if let mask = self.config.settings.audioChannelMask {
                    indices = Array((0..<32).filter { mask & (1 << $0) != 0 }.prefix(2))
                } else {
                    indices = [0, 1]
                }
                if let monitor = PCMAudio.selectChannels(
                    sampleBuffer, indices: indices,
                    formatCache: &self.monitorFormatCache) {
                    onMonitorAudio(monitor)
                }
            }
            if !levels.isEmpty, levels != self.lastPublishedLevels {
                if self.lastPublishedLevels.isEmpty {
                    os_log("audio: %d channel(s) flowing",
                           log: Self.levelsLog, type: .default, levels.count)
                }
                self.lastPublishedLevels = levels
                DispatchQueue.main.async { self.onAudioLevels?(levels) }
            }
        }
    }

    // LTC from an embedded audio channel (all access on queue).
    private let ltcDecoder = LTCDecoder()
    private var latestLTC: Timecode?

    private func decodeLTC(from sampleBuffer: CMSampleBuffer, channels: Int) {
        guard channels > 0, let format else { return }
        let channel = min(max(0, config.settings.ltcChannel ?? 0), channels - 1)
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(
            block, atOffset: 0, lengthAtOffsetOut: nil,
            totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
            let pointer, length >= 2 else { return }
        let fps = format.timecodeFPS
        pointer.withMemoryRebound(to: Int16.self, capacity: length / 2) { samples in
            let frames = (length / 2) / channels
            guard frames > 0 else { return }
            // extract the selected channel from the interleaved stream
            var mono = [Int16](repeating: 0, count: frames)
            for i in 0..<frames {
                mono[i] = samples[i * channels + channel]
            }
            mono.withUnsafeBufferPointer { buffer in
                if let tc = ltcDecoder.process(samples: buffer, fps: fps) {
                    latestLTC = tc
                }
            }
        }
    }

    /// How many channels are actually written under the current mask.
    private var recordChannelCount: Int {
        guard sourceAudioChannels > 0 else { return 0 }
        guard let mask = config.settings.audioChannelMask else { return sourceAudioChannels }
        return (0..<sourceAudioChannels).filter { mask & (1 << $0) != 0 }.count
    }

    // MARK: - processing (on queue)

    /// Tag a frame with colorimetry from settings if the backend didn't report it.
    /// Without tags the preview layer and the player interpret color differently.
    /// The values come from ColorTags — the same table the recorded file uses.
    /// NOTE: the buffer handed to the writer must keep standard tags — the
    /// encoder color-converts pixels when buffer tags mismatch the file tags
    /// (verified on device: a display-gamma tag here darkened recorded shadows).
    private func tagColorIfUntagged(_ pixelBuffer: CVPixelBuffer) {
        guard CVBufferCopyAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey,
                                     nil) == nil else { return }
        ColorTags.tag(pixelBuffer, preset: config.settings.colorTagPreset)
    }

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
                self?.queue.async { self?.scopeBusy = false }
                if let data {
                    DispatchQueue.main.async { self?.onScopeData?(data) }
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
    private var recordingMask: Int?

    // TC-run onset detection for the mid-take timecode re-anchor.
    private var lastWireTimecode: Timecode?
    private var frozenTCStreak = 0

    private var frameGrabHandler: ((Data?) -> Void)?

    /// Grab the next displayed frame as PNG (WYSIWYG with levels/preview LUT).
    /// The handler fires once, on the main queue.
    public func grabNextFrame(_ handler: @escaping (Data?) -> Void) {
        queue.async { self.frameGrabHandler = handler }
    }

    public static func pngData(from pixelBuffer: CVPixelBuffer,
                               ciContext: CIContext) -> Data? {
        // identity conversion, PNG tagged with the same ICC "HDTV" (Rec.709)
        // space the preview and the ProRes decoder use — the still looks
        // exactly like the player in any color-managed viewer
        let attachments = [
            kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kCVImageBufferTransferFunctionKey: kCVImageBufferTransferFunction_ITU_R_709_2,
            kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        ] as CFDictionary
        let space = CVImageBufferCreateColorSpaceFromAttachments(attachments)?
            .takeRetainedValue()
            ?? CGColorSpace(name: CGColorSpace.itur_709)
            ?? CGColorSpaceCreateDeviceRGB()
        let image = CIImage(cvPixelBuffer: pixelBuffer,
                            options: [.colorSpace: space])
        return ciContext.pngRepresentation(of: image, format: .RGBA8,
                                           colorSpace: space)
    }

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
    private var preRollFrames: Int {
        config.settings.preRollFramesEffective
    }

    /// Keep the pre-roll window's audio, trimmed to a little more than the
    /// window itself. Raw packets: the channel mask is latched when the take
    /// starts, so the trim happens at drain time. ~60 KB per 40 ms packet at
    /// 16 channels, so even a long lead costs single-digit megabytes.
    /// Write the buffered pre-roll audio into a take that has just started,
    /// trimmed with the mask latched for this take. Packets older than the
    /// take's first video frame have nowhere to go and are discarded.
    private func drainPreRollAudio(into writer: TakeWriter, from start: CMTime?) {
        defer { preRollAudio.removeAll() }
        guard let start else { return }
        for buffered in preRollAudio where buffered.pts >= start {
            var toWrite: CMSampleBuffer? = buffered.buffer
            if let mask = recordingMask {
                let indices = (0..<32).filter { mask & (1 << $0) != 0 }
                toWrite = PCMAudio.selectChannels(buffered.buffer, indices: indices,
                                                  formatCache: &trimFormatCache)
            }
            if let toWrite { writer.append(audioSampleBuffer: toWrite) }
        }
    }

    private func bufferPreRollAudio(_ sampleBuffer: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid else { return }
        preRollAudio.append((pts: pts, buffer: sampleBuffer))
        let fps = format?.frameRate ?? 25
        let window = Double(preRollFrames) / max(1, fps) + 1.0 // slack for jitter
        while let first = preRollAudio.first,
              (pts - first.pts).seconds > window {
            preRollAudio.removeFirst()
        }
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
    private static let reservationLock = NSLock()
    private static var reservedPaths: Set<String> = []

    public static func uniqueURL(for url: URL) -> URL {
        reservationLock.lock()
        defer { reservationLock.unlock() }

        func taken(_ candidate: URL) -> Bool {
            FileManager.default.fileExists(atPath: candidate.path)
                || reservedPaths.contains(candidate.path)
        }

        if !taken(url) {
            reservedPaths.insert(url.path)
            return url
        }
        let base = url.deletingPathExtension()
        let ext = url.pathExtension
        var attempt = 2
        while attempt < 1000 {
            let candidate = URL(fileURLWithPath: base.path + "_\(attempt)")
                .appendingPathExtension(ext)
            if !taken(candidate) {
                reservedPaths.insert(candidate.path)
                return candidate
            }
            attempt += 1
        }
        let fallback = URL(fileURLWithPath: base.path + "_\(UUID().uuidString)")
            .appendingPathExtension(ext)
        reservedPaths.insert(fallback.path)
        return fallback
    }

    /// Drop a reservation once the file exists on disk (or the take failed to
    /// start) — from then on the filesystem itself is the authority.
    public static func releaseReservation(for url: URL) {
        reservationLock.lock()
        reservedPaths.remove(url.path)
        reservationLock.unlock()
    }

    private func beginTake(timecode rawTimecode: Timecode?, recStartIndex: Int? = nil) {
        guard writer == nil, let format else { return }
        recordingMask = config.settings.audioChannelMask // latched for the take
        // The file's TC track counts from its FIRST frame — which is pre-roll,
        // shot before the camera's TC started running. Shift the start TC back
        // by the pre-roll frames actually written, so the camera-start frame
        // carries exactly the camera's TC and the take stays sync-accurate
        // against the camera original.
        let startIndex = recStartIndex ?? frameIndex
        let cutoffPreview = max(0, startIndex - preRollFrames)
        // only the frames written BEFORE the camera-start frame shift the TC —
        // counting the detection-latency frames too made every take a few
        // frames early against the camera original
        let preStartCount = preRollBuffer.filter {
            $0.index >= cutoffPreview && $0.index < startIndex
        }.count
        var timecode = rawTimecode
        if let tc = rawTimecode, preStartCount > 0 {
            let dayFrames = Timecode.dayFrames(fps: tc.fps,
                                               isDropFrame: tc.isDropFrame)
            var shifted = tc.frameNumber - preStartCount
            if shifted < 0 { shifted += dayFrames } // wrap across midnight
            timecode = Timecode(frameNumber: shifted,
                                fps: tc.fps, isDropFrame: tc.isDropFrame)
        }
        let engine = NamingEngine(template: config.settings.namingTemplate)
        let context = NamingContext(
            project: config.settings.projectName,
            date: Date(),
            scene: config.scene,
            take: config.takeNumber,
            reel: config.roll,
            camera: config.settings.cameraLabel,
            clipName: "",
            postfix: config.settings.postfix ?? "",
            clipPadding: config.settings.clipPadWidthEffective,
            timecode: timecode)
        let root = URL(fileURLWithPath:
            (config.settings.destinationPath as NSString).expandingTildeInPath)
        // write STRAIGHT into the chosen folder — no auto subfolders by date/project:
        // the DIT picks the card/roll folder themselves; app nesting surprises them.
        // takes are never overwritten: on a name collision — suffix _2, _3…
        // (typical case: the clip counter restarted and last session's files with
        // the same names are already in the folder)
        let url = Self.uniqueURL(for: root
            .appendingPathComponent(engine.fileName(for: context))
            .appendingPathExtension("mov"))
        // the writer creates the file straight away, so the filesystem takes
        // over from the reservation whichever way this goes
        defer { Self.releaseReservation(for: url) }
        do {
            let writer = try TakeWriter(
                url: url, format: format,
                codec: config.settings.codec, startTimecode: timecode,
                markerMetadata: {
                    var meta = [
                        TakeWriter.rollKey: config.roll,
                        TakeWriter.clipKey: String(config.takeNumber),
                    ]
                    // tag a file with a baked-in LUT: playback won't apply the LUT again
                    if lutRecord, let lutName {
                        meta[TakeWriter.lutKey] = lutName
                    }
                    return meta
                }(),
                colorTagPreset: config.settings.colorTagPreset,
                audioChannelCount: recordChannelCount)
            self.writer = writer
            takeStartTC = timecode
            takeStartedAt = Date()
            takeScene = config.scene
            takeRoll = config.roll
            takeNumber = config.takeNumber
            droppedFrames = 0

            // The writer's audio input is created from the channel count learned
            // from the first audio packet. A take that starts before any packet
            // has arrived — relaunch or device restart while the camera is
            // already rolling, where a VANC trigger fires on capture frame 1 —
            // gets no audio input at all, and every packet of the take is then
            // discarded without a counter. Say so: silent scratch audio is only
            // discovered in the edit.
            if recordChannelCount == 0 {
                DispatchQueue.main.async {
                    self.onError?("TAKE LOST audio — \(url.lastPathComponent) "
                        + "started before the audio format was known and has no "
                        + "audio track")
                }
            }

            // pull frames from the buffer from (camera start - pre-roll) to current;
            // in Rec Run their timecode is frozen at the start value, so the take's
            // timecode track stays correct
            let cutoff = max(0, (recStartIndex ?? frameIndex) - preRollFrames)
            // the burst outruns the encoder queue — wait, but within a total
            // budget: unbounded waits stall the pipeline queue while capture
            // callbacks pile up retained 4K frames behind it
            let drainDeadline = Date().addingTimeInterval(1.5)
            var lostPreRoll = 0
            var firstPreRollPTS: CMTime?
            for buffered in preRollBuffer where buffered.index >= cutoff {
                let frame = lutRecord
                    ? (applyLUT(to: buffered.pixelBuffer) ?? buffered.pixelBuffer)
                    : buffered.pixelBuffer
                if writer.appendBuffered(pixelBuffer: frame, pts: buffered.pts,
                                         deadline: drainDeadline) {
                    if firstPreRollPTS == nil { firstPreRollPTS = buffered.pts }
                } else {
                    lostPreRoll += 1
                }
            }
            preRollBuffer.removeAll()
            // ...and the sound that goes under those frames. The writer's session
            // starts at the first video PTS above, so anything older than that
            // cannot be placed and is dropped.
            drainPreRollAudio(into: writer, from: firstPreRollPTS)
            // once the drain budget is spent the rest of the burst is dropped —
            // and those are the frames closest to the camera's REC press, the
            // whole point of pre-roll. Silence here reads as a clean head.
            if lostPreRoll > 0 {
                let count = lostPreRoll
                DispatchQueue.main.async {
                    self.onError?("Pre-roll incomplete: \(count) frame(s) "
                        + "before the REC point were not written")
                }
            }

            DispatchQueue.main.async { self.onRecStateChanged?(true) }
        } catch {
            DispatchQueue.main.async {
                self.onError?("Failed to start recording: \(error.localizedDescription)")
            }
        }
    }

    /// How many frames a take must lose before the sticky alarm fires. One
    /// isolated drop at take start is normal encoder back-pressure; sustained
    /// loss is not.
    static let droppedFrameAlarmThreshold = 5

    /// Suffix that marks a take whose finalize failed. Renaming is best-effort:
    /// if it does not work the original path is returned and the operator still
    /// gets the alarm.
    static let failedTakeSuffix = "_FAILED"

    static func markFailed(_ url: URL) -> URL {
        let name = url.deletingPathExtension().lastPathComponent
        guard !name.hasSuffix(failedTakeSuffix) else { return url }
        let renamed = url.deletingLastPathComponent()
            .appendingPathComponent(name + failedTakeSuffix)
            .appendingPathExtension(url.pathExtension)
        let target = uniqueURL(for: renamed)
        do {
            try FileManager.default.moveItem(at: url, to: target)
            return target
        } catch {
            return url
        }
    }

    private func finishTake() {
        guard let writer else { return }
        self.writer = nil
        let take = Take(
            url: writer.url,
            displayName: writer.url.deletingPathExtension().lastPathComponent,
            scene: takeScene,
            roll: takeRoll,
            takeNumber: takeNumber,
            startTimecode: takeStartTC,
            durationSeconds: writer.durationSeconds,
            recordedAt: takeStartedAt)
        DispatchQueue.main.async {
            self.onRecStateChanged?(false)
        }
        // the take joins the list only after a SUCCESSFUL finalize — a failed
        // finish used to leave a normal-looking, unplayable file in the panel
        // pruned by the task itself: the handles are only awaited at capture
        // stop and at quit, and a shooting day never stops capture — the list
        // would otherwise hold one handle per take until the app exits
        let finishID = nextFinishID
        nextFinishID += 1
        let droppedVideo = droppedFrames
        let task = Task { [weak self] in
            defer {
                self?.queue.async {
                    self?.pendingFinishTasks.removeValue(forKey: finishID)
                }
            }
            do {
                _ = try await writer.finish()
                let droppedAudio = writer.droppedAudioPackets
                DispatchQueue.main.async {
                    self?.onTakeFinished?(take)
                    if droppedAudio > 0 {
                        self?.onError?("Take \(take.displayName): "
                            + "\(droppedAudio) audio packet(s) dropped")
                    }
                    // the live alarm only fires on sustained loss, so the take's
                    // real total is stated here — quietly, but never hidden
                    if droppedVideo > 0 {
                        self?.onError?("Take \(take.displayName): "
                            + "\(droppedVideo) video frame(s) dropped")
                    }
                }
            } catch {
                // The half-written file keeps the com.takeshot.origin tag from
                // its initial moov, so the folder scan re-adopts it within
                // seconds and it sits in the panel looking like a healthy take.
                // It is not deleted — with fragmented moov atoms most of it is
                // usually still recoverable — but it must not pass for good
                // footage in the panel or in the log handed to post.
                let marked = Self.markFailed(take.url)
                DispatchQueue.main.async {
                    self?.onError?("TAKE LOST — failed to finalize "
                        + "\(marked.deletingPathExtension().lastPathComponent): "
                        + error.localizedDescription)
                }
            }
        }
        pendingFinishTasks[finishID] = task
    }

    /// Await finalization of all files still being written (capture stop, exit).
    public func finishPendingWrites() async {
        let tasks: [Task<Void, Never>] = await withCheckedContinuation { cont in
            queue.async {
                let snapshot = Array(self.pendingFinishTasks.values)
                self.pendingFinishTasks.removeAll()
                cont.resume(returning: snapshot)
            }
        }
        for task in tasks { await task.value }
    }

    /// Run a frame through the LUT (CoreImage, GPU). nil — if no LUT set/on error.
    private func applyLUT(to pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        guard let filter = lutFilter else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard let outBuffer = lutBufferPool.buffer(width: width, height: height) else {
            return nil
        }

        // raw code values on both ends: .cube LUTs are defined on gamma-encoded
        // codes, and the playback tap renders the same way — a color-managed
        // render here made live and playback diverge with the LUT on
        let input = CIImage(cvPixelBuffer: pixelBuffer,
                            options: [.colorSpace: NSNull()])
        filter.setValue(input, forKey: kCIInputImageKey)
        guard let output = filter.outputImage else { return nil }
        let finalImage = Self.mix(source: input, filtered: output,
                                  intensity: lutIntensity)
        let destination = CIRenderDestination(pixelBuffer: outBuffer)
        destination.colorSpace = nil
        // a failed render MUST NOT hand uninitialized pool memory to the writer
        guard let task = try? ciContext.startTask(toRender: finalImage,
                                                  to: destination),
              (try? task.waitUntilCompleted()) != nil else { return nil }
        tagColorIfUntagged(outBuffer)
        return outBuffer
    }

    /// Expansion table 16-235 → 0-255 for limited-range RGB inputs. Defined on
    /// gamma-encoded code values, so it must run on raw bytes — a CIColorMatrix
    /// in CI's linear working space crushes shadows and dulls highlights.
    private static let levelsExpandTable: [UInt8] = (0...255).map {
        UInt8(min(255, max(0, Int((Double($0) - 16) * 255 / 219 + 0.5))))
    }
    private static let levelsTableIdentity: [UInt8] = (0...255).map { UInt8($0) }

    /// Expand limited-range (16-235) RGB to full range, in place (vImage byte
    /// lookup — no CoreImage pass, no extra buffer). BGRA only: this is the
    /// single levels operation in the pipeline; the encoder handles full-RGB →
    /// legal-YUV for the file, and YUV sources are legal-range by definition.
    private func expandLimitedRGB(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA
        else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        var image = vImage_Buffer(
            data: base,
            height: vImagePixelCount(CVPixelBufferGetHeight(pixelBuffer)),
            width: vImagePixelCount(CVPixelBufferGetWidth(pixelBuffer)),
            rowBytes: CVPixelBufferGetBytesPerRow(pixelBuffer))
        // byte order is B G R A: remap the three color channels, keep alpha
        let error = Self.levelsExpandTable.withUnsafeBufferPointer { lut in
            Self.levelsTableIdentity.withUnsafeBufferPointer { identity in
                vImageTableLookUp_ARGB8888(&image, &image,
                                           lut.baseAddress!, lut.baseAddress!,
                                           lut.baseAddress!, identity.baseAddress!,
                                           vImage_Flags(kvImageNoFlags))
            }
        }
        return error == kvImageNoError ? pixelBuffer : nil
    }

    /// Blend the original and LUT'd frame by intensity (cross-dissolve).
    public static func mix(source: CIImage, filtered: CIImage,
                           intensity: Double) -> CIImage {
        guard intensity < 0.999 else { return filtered }
        guard let dissolve = CIFilter(name: "CIDissolveTransition") else { return filtered }
        dissolve.setValue(source, forKey: "inputImage")
        dissolve.setValue(filtered, forKey: "inputTargetImage")
        dissolve.setValue(intensity, forKey: "inputTime")
        return dissolve.outputImage ?? filtered
    }

    private let latestPreviewLock = NSLock()
    private var latestPreview: CVPixelBuffer?

    /// The most recent processed preview frame (levels/LUT applied) — pulled by
    /// the playback tap for the compare modes. Thread-safe.
    public func currentPreviewBuffer() -> CVPixelBuffer? {
        latestPreviewLock.lock()
        defer { latestPreviewLock.unlock() }
        return latestPreview
    }

    // Presentation runs on its own queue with latest-wins coalescing:
    // MetalPreviewLayer.present renders + waits on the GPU and nextDrawable()
    // can park for a vsync when the window is occluded — none of that may
    // stall the capture-critical queue.
    private let displayQueue = DispatchQueue(label: "takeshot.display",
                                             qos: .userInteractive)
    private let presentLock = NSLock()
    private var pendingPresent: CVPixelBuffer?
    private var presentScheduled = false

    /// `pixelBuffer` is the clean processed frame (compare provider, pinning);
    /// `screen` is what the preview sinks draw (may carry the reference wipe).
    private func enqueuePreview(pixelBuffer: CVPixelBuffer,
                                screen: CVPixelBuffer? = nil) {
        latestPreviewLock.lock()
        latestPreview = pixelBuffer
        latestPreviewLock.unlock()
        let presented = screen ?? pixelBuffer
        presentLock.lock()
        pendingPresent = presented
        let schedule = !presentScheduled
        presentScheduled = true
        presentLock.unlock()
        guard schedule else { return } // a newer frame replaces the pending one
        displayQueue.async { [weak self] in
            guard let self else { return }
            self.presentLock.lock()
            let buffer = self.pendingPresent
            self.pendingPresent = nil
            self.presentScheduled = false
            self.presentLock.unlock()
            guard let buffer else { return }
            self.displaySinks.present(buffer)
            self.displayFrameLock.lock()
            let handler = self.displayFrameHandler
            self.displayFrameLock.unlock()
            handler?(buffer)
        }
    }
}
