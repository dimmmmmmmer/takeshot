import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation

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

    public let displayLayer = AVSampleBufferDisplayLayer()
    /// Second layer — for output to an external monitor. Frames are mirrored
    /// only when externalMirrorEnabled == true (the copy is cheap).
    public let externalLayer = AVSampleBufferDisplayLayer()
    public var externalMirrorEnabled = false
    /// Third layer — the live fullscreen window (player fills the screen).
    public let fullscreenLayer = AVSampleBufferDisplayLayer()
    public var fullscreenMirrorEnabled = false

    // LUT (all access on queue)
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var lutFilter: CIFilter?
    private var lutName: String?
    private var lutPreview = false
    private var lutRecord = false
    private var lutIntensity: Double = 1
    private let lutBufferPool = PixelBufferPool()
    /// Level processing ("limited"/"full"/nil) — a pixel remap.
    private var levelsMode: String?

    /// Video-level processing mode applied to pixels.
    public func setVideoLevels(_ mode: String?) {
        queue.async { self.levelsMode = (mode == "auto") ? nil : mode }
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
    private var videoFormatDescription: CMVideoFormatDescription?
    /// Frames before record start — for pre-roll (only while writer == nil).
    private var preRollBuffer: [(index: Int, pixelBuffer: CVPixelBuffer, pts: CMTime)] = []
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
            stopDebounceFrames: config.settings.stopDebounceFrames))
    }

    // MARK: - control (from MainActor)

    public func update(config: Config) {
        queue.async {
            let debounceChanged =
                config.settings.startDebounceFrames != self.config.settings.startDebounceFrames
                || config.settings.stopDebounceFrames != self.config.settings.stopDebounceFrames
            self.config = config
            if debounceChanged {
                self.detector = RecDetector(config: RecDetectorConfig(
                    startDebounceFrames: config.settings.startDebounceFrames,
                    stopDebounceFrames: config.settings.stopDebounceFrames))
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
            self.videoFormatDescription = nil
            self.preRollBuffer.removeAll()
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
            self.format = newFormat
            self.detector.reset()
            self.videoFormatDescription = nil
            self.preRollBuffer.removeAll()
            DispatchQueue.main.async { self.onFormatChanged?(newFormat) }
        }
    }

    public func handleSignal(present: Bool) {
        DispatchQueue.main.async { self.onSignal?(present) }
    }

    public func handleFrame(pixelBuffer: CVPixelBuffer, pts: CMTime,
                     timecode rawTimecode: Timecode?, vancTrigger: VancTrigger? = nil,
                     ancillaryPackets: [AncillaryPacket] = []) {
        queue.async {
            self.processFrame(pixelBuffer: pixelBuffer, pts: pts,
                              timecode: rawTimecode, vancTrigger: vancTrigger,
                              ancillaryPackets: ancillaryPackets)
        }
    }

    private var trimFormatCache: CMAudioFormatDescription?
    /// Input audio channel count (cached even during preview — so the writer
    /// knows the audio input format up front, before the first record packet).
    private var sourceAudioChannels = 0

    public func handleAudio(_ sampleBuffer: CMSampleBuffer) {
        queue.async {
            let levels = PCMAudio.peakLevels(of: sampleBuffer)
            self.sourceAudioChannels = levels.count
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
            if !levels.isEmpty {
                DispatchQueue.main.async { self.onAudioLevels?(levels) }
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
        lastTimecode = timecode

        // while not recording — accumulate frames into the pre-roll buffer (current
        // frame included): when a take starts, frames from the camera's actual record
        // start (lost to debounce) plus the configured lead seconds are pulled from it
        if writer == nil {
            preRollBuffer.append((index: frameIndex, pixelBuffer: pixelBuffer, pts: pts))
            let capacity = preRollCapacity
            if preRollBuffer.count > capacity {
                preRollBuffer.removeFirst(preRollBuffer.count - capacity)
            }
        }

        // levels first (pixel remap), shared by preview and recording —
        // it's part of the signal, not a "look" like the LUT
        let leveled = levelsMode != nil ? (applyLevels(to: pixelBuffer) ?? pixelBuffer)
                                        : pixelBuffer
        // LUT: preview may have the LUT while recording stays clean (or vice versa)
        let displayBuffer = lutPreview
            ? (applyLUT(to: leveled) ?? leveled) : leveled
        let recordBuffer = lutRecord
            ? (lutPreview ? displayBuffer : (applyLUT(to: leveled) ?? leveled))
            : leveled

        var startedThisFrame = false
        let mode = config.settings.detectionMode
        if mode != .manual {
            let sample = FrameSample(index: frameIndex, timecode: timecode,
                                     vancTrigger: mode == .auto ? vancTrigger : nil)
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

        if !startedThisFrame, let writer,
           !writer.append(pixelBuffer: recordBuffer, pts: pts) {
            droppedFrames += 1
            if droppedFrames == 1 || droppedFrames % 100 == 0 {
                let count = droppedFrames
                DispatchQueue.main.async {
                    self.onError?("Dropped \(count) recording frame(s) — disk too slow")
                }
            }
        }

        // one-shot frame grab: PNG of exactly what's on screen (levels + preview LUT)
        if let grab = frameGrabHandler {
            frameGrabHandler = nil
            let png = Self.pngData(from: displayBuffer, ciContext: ciContext)
            DispatchQueue.main.async { grab(png) }
        }

        enqueuePreview(pixelBuffer: displayBuffer)
        DispatchQueue.main.async { self.onTimecode?(timecode) }
    }

    private var frameGrabHandler: ((Data?) -> Void)?

    /// Grab the next displayed frame as PNG (WYSIWYG with levels/preview LUT).
    /// The handler fires once, on the main queue.
    public func grabNextFrame(_ handler: @escaping (Data?) -> Void) {
        queue.async { self.frameGrabHandler = handler }
    }

    private static func pngData(from pixelBuffer: CVPixelBuffer,
                                ciContext: CIContext) -> Data? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let space = CGColorSpace(name: CGColorSpace.itur_709)
            ?? CGColorSpaceCreateDeviceRGB()
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

    /// Pre-roll frame count at the current format.
    private var preRollFrames: Int {
        let fps = format?.frameRate ?? 25
        return Int((config.settings.preRollSecondsEffective * fps).rounded())
    }

    /// Buffer capacity: pre-roll + detection latency + slack, but with a memory
    /// cap. Without the cap, 3 s of pre-roll at 4K60 holds ~6 GB of uncompressed
    /// frames in RAM (OOM); at high resolution the pre-roll quietly shortens.
    private var preRollCapacity: Int {
        let wanted = preRollFrames + config.settings.startDebounceFrames + 25
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

    private func beginTake(timecode: Timecode?, recStartIndex: Int? = nil) {
        guard writer == nil, let format else { return }
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
            for buffered in preRollBuffer where buffered.index >= cutoff {
                let frame = lutRecord
                    ? (applyLUT(to: buffered.pixelBuffer) ?? buffered.pixelBuffer)
                    : buffered.pixelBuffer
                writer.append(pixelBuffer: frame, pts: buffered.pts)
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

        let input = CIImage(cvPixelBuffer: pixelBuffer)
        filter.setValue(input, forKey: kCIInputImageKey)
        guard let output = filter.outputImage else { return nil }
        let finalImage = Self.mix(source: input, filtered: output,
                                  intensity: lutIntensity)
        ciContext.render(finalImage, to: outBuffer, bounds: input.extent,
                         colorSpace: CGColorSpace(name: CGColorSpace.itur_709))
        tagColorIfUntagged(outBuffer)
        return outBuffer
    }

    private let levelsBufferPool = PixelBufferPool()

    /// Pixel-level remap: "limited" compresses full(0-255)→legal(16-235),
    /// "full" stretches legal→full. Uses CIColorMatrix (scale+bias).
    private func applyLevels(to pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        guard let mode = levelsMode else { return nil }
        let scale: CGFloat, bias: CGFloat
        switch mode {
        case "limited": scale = 219.0 / 255.0; bias = 16.0 / 255.0   // full -> legal
        case "full":    scale = 255.0 / 219.0; bias = -16.0 / 219.0   // legal -> full
        default: return nil
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard let outBuffer = levelsBufferPool.buffer(width: width, height: height),
              let matrix = CIFilter(name: "CIColorMatrix") else { return nil }
        let input = CIImage(cvPixelBuffer: pixelBuffer)
        matrix.setValue(input, forKey: kCIInputImageKey)
        matrix.setValue(CIVector(x: scale, y: 0, z: 0, w: 0), forKey: "inputRVector")
        matrix.setValue(CIVector(x: 0, y: scale, z: 0, w: 0), forKey: "inputGVector")
        matrix.setValue(CIVector(x: 0, y: 0, z: scale, w: 0), forKey: "inputBVector")
        matrix.setValue(CIVector(x: bias, y: bias, z: bias, w: 0), forKey: "inputBiasVector")
        guard let output = matrix.outputImage else { return nil }
        ciContext.render(output, to: outBuffer, bounds: input.extent,
                         colorSpace: CGColorSpace(name: CGColorSpace.itur_709))
        tagColorIfUntagged(outBuffer)
        return outBuffer
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

    private func enqueuePreview(pixelBuffer: CVPixelBuffer) {
        if videoFormatDescription.map({
            !CMVideoFormatDescriptionMatchesImageBuffer($0, imageBuffer: pixelBuffer)
        }) ?? true {
            var formatDescription: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                formatDescriptionOut: &formatDescription)
            videoFormatDescription = formatDescription
        }
        guard let videoFormatDescription else { return }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
            formatDescription: videoFormatDescription, sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer) == noErr, let sampleBuffer else { return }

        // display immediately, not tied to the player clock
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: true) as? [CFMutableDictionary],
           let first = attachments.first {
            CFDictionarySetValue(
                first,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }

        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        displayLayer.enqueue(sampleBuffer)

        for (enabled, layer) in [(externalMirrorEnabled, externalLayer),
                                 (fullscreenMirrorEnabled, fullscreenLayer)] where enabled {
            var copy: CMSampleBuffer?
            CMSampleBufferCreateCopy(allocator: kCFAllocatorDefault,
                                     sampleBuffer: sampleBuffer,
                                     sampleBufferOut: &copy)
            if let copy {
                if layer.status == .failed {
                    layer.flush()
                }
                layer.enqueue(copy)
            }
        }
    }
}
