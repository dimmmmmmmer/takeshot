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

    /// Live preview sinks: every SwiftUI mount registers its OWN layer. A
    /// CALayer can be hosted by only one NSView — sharing a single layer
    /// between the main preview, compare and multicam tiles let the
    /// last-mounted view steal it, and the survivor drew with the thief's
    /// stale geometry (image pinned to an edge instead of centered).
    private let displaySinksLock = NSLock()
    private let displaySinks = NSHashTable<MetalPreviewLayer>.weakObjects()
    private var sinkLetterbox = CIColor(red: 0, green: 0, blue: 0)

    public func addDisplaySink(_ layer: MetalPreviewLayer) {
        displaySinksLock.lock()
        layer.letterboxColor = sinkLetterbox
        displaySinks.add(layer)
        displaySinksLock.unlock()
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
        displaySinksLock.lock()
        displaySinks.remove(layer)
        displaySinksLock.unlock()
    }

    public func setPreviewLetterbox(_ color: CIColor) {
        displaySinksLock.lock()
        sinkLetterbox = color
        let sinks = displaySinks.allObjects
        displaySinksLock.unlock()
        for sink in sinks {
            sink.letterboxColor = color
            sink.redraw()
        }
    }

    private func allDisplaySinks() -> [MetalPreviewLayer] {
        displaySinksLock.lock()
        defer { displaySinksLock.unlock() }
        return displaySinks.allObjects
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

    // fitted reference is invariant per (buffer, extent) — rebuilt only when
    // the pin or the live frame size changes
    private var fittedReferenceCache: (source: CVPixelBuffer, extent: CGRect,
                                       image: CIImage)?

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
            fittedReferenceCache = (reference, back.extent, front)
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
    /// Accumulated VANC stats by (DID, SDID).
    private var vancStats: [String: VancPacketStat] = [:]
    private var vancStatsDirty = false
    private var vancStatsLastPublish = 0
    /// Pending file-finalization tasks (awaited on stop/exit).
    private var pendingFinishTasks: [Task<Void, Never>] = []

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
            self.preRollBuffer.removeAll()
            self.latestPreviewLock.lock()
            self.latestPreview = nil // don't compare against a frozen frame
            self.latestPreviewLock.unlock()
            self.vancStats.removeAll()
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
            self.format = newFormat
            self.detector.reset()
            self.preRollBuffer.removeAll()
            DispatchQueue.main.async { self.onFormatChanged?(newFormat) }
        }
    }

    public func handleSignal(present: Bool) {
        if !present {
            // no frozen last frame on signal loss — show black
            for sink in allDisplaySinks() { sink.clearToBlack() }
        }
        DispatchQueue.main.async { self.onSignal?(present) }
    }

    public func handleFrame(pixelBuffer: CVPixelBuffer, pts: CMTime,
                            timecode rawTimecode: Timecode?,
                            vancTrigger: VancTrigger? = nil,
                            ancillaryPackets: [AncillaryPacket] = []) {
        queue.async {
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

    public func handleAudio(_ sampleBuffer: CMSampleBuffer) {
        queue.async {
            let levels = PCMAudio.peakLevels(of: sampleBuffer)
            self.sourceAudioChannels = levels.count
            if self.config.settings.timecodeSource == "ltc" {
                self.decodeLTC(from: sampleBuffer, channels: levels.count)
            }
            // meters show ALL channels; only channels enabled in the mask are written
            var toWrite: CMSampleBuffer? = sampleBuffer
            if let mask = self.config.settings.audioChannelMask {
                let indices = (0..<32).filter { mask & (1 << $0) != 0 }
                toWrite = PCMAudio.selectChannels(sampleBuffer, indices: indices,
                                                  formatCache: &self.trimFormatCache)
            }
            if let toWrite {
                self.writer?.append(audioSampleBuffer: toWrite)
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
        guard CVBufferGetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey,
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
            // the pre-roll must hold what the WRITER gets (10-bit when active)
            preRollBuffer.append(PreRollFrame(index: frameIndex,
                                              pixelBuffer: tenBitRecord ?? leveled,
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
            droppedFrames += 1
            if droppedFrames == 1 || droppedFrames % 100 == 0 {
                let count = droppedFrames
                DispatchQueue.main.async {
                    self.onError?("Dropped \(count) recording frame(s) — encoder/disk can't keep up")
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

    // TC-run onset detection for the mid-take timecode re-anchor.
    private var lastWireTimecode: Timecode?
    private var frozenTCStreak = 0

    private var frameGrabHandler: ((Data?) -> Void)?

    /// Grab the next displayed frame as PNG (WYSIWYG with levels/preview LUT).
    /// The handler fires once, on the main queue.
    public func grabNextFrame(_ handler: @escaping (Data?) -> Void) {
        queue.async { self.frameGrabHandler = handler }
    }

    private static func pngData(from pixelBuffer: CVPixelBuffer,
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

    private func updateVancStats(_ packets: [AncillaryPacket]) {
        for packet in packets {
            let key = String(format: "%02X/%02X", packet.did, packet.sdid)
            let hex = packet.data.prefix(24)
                .map { String(format: "%02X", $0) }.joined(separator: " ")
            let previous = vancStats[key]
            vancStats[key] = VancPacketStat(
                did: packet.did, sdid: packet.sdid,
                count: (previous?.count ?? 0) + 1,
                lastLine: packet.lineNumber, lastDataHex: hex)
            vancStatsDirty = true
        }
        // publish at most ~once a second so we don't poke the UI every frame
        let interval = Int(format?.frameRate.rounded() ?? 25)
        if vancStatsDirty, frameIndex - vancStatsLastPublish >= interval {
            vancStatsDirty = false
            vancStatsLastPublish = frameIndex
            let stats = vancStats.values.sorted { $0.key < $1.key }
            DispatchQueue.main.async { self.onVancStats?(stats) }
        }
    }

    /// Pre-roll frame count (a direct frames setting, fps-independent).
    private var preRollFrames: Int {
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
    public static func uniqueURL(for url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension()
        let ext = url.pathExtension
        var attempt = 2
        while attempt < 1000 {
            let candidate = URL(fileURLWithPath: base.path + "_\(attempt)")
                .appendingPathExtension(ext)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            attempt += 1
        }
        return URL(fileURLWithPath: base.path + "_\(UUID().uuidString)")
            .appendingPathExtension(ext)
    }

    private func beginTake(timecode rawTimecode: Timecode?, recStartIndex: Int? = nil) {
        guard writer == nil, let format else { return }
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
            let dayFrames = 24 * 3600 * max(1, tc.fps)
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

            // pull frames from the buffer from (camera start - pre-roll) to current;
            // in Rec Run their timecode is frozen at the start value, so the take's
            // timecode track stays correct
            let cutoff = max(0, (recStartIndex ?? frameIndex) - preRollFrames)
            // the burst outruns the encoder queue — wait, but within a total
            // budget: unbounded waits stall the pipeline queue while capture
            // callbacks pile up retained 4K frames behind it
            let drainDeadline = Date().addingTimeInterval(1.5)
            for buffered in preRollBuffer where buffered.index >= cutoff {
                let frame = lutRecord
                    ? (applyLUT(to: buffered.pixelBuffer) ?? buffered.pixelBuffer)
                    : buffered.pixelBuffer
                writer.appendBuffered(pixelBuffer: frame, pts: buffered.pts,
                                      deadline: drainDeadline)
            }
            preRollBuffer.removeAll()

            DispatchQueue.main.async { self.onRecStateChanged?(true) }
        } catch {
            DispatchQueue.main.async {
                self.onError?("Failed to start recording: \(error.localizedDescription)")
            }
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
            self.onTakeFinished?(take)
        }
        // track the finalization task so we can await it on capture stop and app
        // exit (otherwise the file may be left unfinished)
        let task = Task { [weak self] in
            do {
                _ = try await writer.finish()
            } catch {
                DispatchQueue.main.async {
                    self?.onError?("Failed to finalize take: \(error.localizedDescription)")
                }
            }
        }
        pendingFinishTasks.append(task)
    }

    /// Await finalization of all files still being written (capture stop, exit).
    public func finishPendingWrites() async {
        let tasks: [Task<Void, Never>] = await withCheckedContinuation { cont in
            queue.async {
                let snapshot = self.pendingFinishTasks
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
        if let task = try? ciContext.startTask(toRender: finalImage,
                                               to: destination) {
            _ = try? task.waitUntilCompleted()
        }
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
            for sink in self.allDisplaySinks() { sink.present(buffer) }
        }
    }
}
