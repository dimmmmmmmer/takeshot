import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// Конвейер кадров: принимает колбэки бэкенда (с потоков захвата), гонит их через
/// RecDetector, пишет дубли через TakeWriter и кормит превью. Вся работа — на
/// собственной серийной очереди, на MainActor уходят только UI-события.
///
/// @unchecked Sendable: всё мутабельное состояние трогается только на `queue`;
/// UI-колбэки назначаются один раз до старта захвата и вызываются на main.
public final class CapturePipeline: @unchecked Sendable {
    public struct Config {
        public var settings: CaptureSettings
        public var scene: String
        public var takeNumber: Int

        public init(settings: CaptureSettings, scene: String, takeNumber: Int) {
            self.settings = settings
            self.scene = scene
            self.takeNumber = takeNumber
        }
    }

    // UI-колбэки, вызываются на главной очереди
    public var onFormatChanged: ((CaptureFormat?) -> Void)?
    public var onTimecode: ((Timecode?) -> Void)?
    public var onRecStateChanged: ((Bool) -> Void)?
    public var onTakeFinished: ((Take) -> Void)?
    public var onSignal: ((Bool) -> Void)?
    public var onError: ((String) -> Void)?

    public let displayLayer = AVSampleBufferDisplayLayer()

    private let queue = DispatchQueue(label: "takeshot.pipeline", qos: .userInitiated)

    // состояние конвейера — только на queue
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
    private var takeNumber = 0
    private var videoFormatDescription: CMVideoFormatDescription?

    public init(config: Config) {
        self.config = config
        self.detector = RecDetector(config: RecDetectorConfig(
            startDebounceFrames: config.settings.startDebounceFrames,
            stopDebounceFrames: config.settings.stopDebounceFrames))
    }

    // MARK: - управление (с MainActor)

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

    /// Ручной старт/стоп записи (кнопка).
    public func toggleManualRecord() {
        queue.async {
            if self.writer != nil {
                self.finishTake()
            } else {
                self.beginTake(timecode: self.lastTimecode)
            }
        }
    }

    /// Остановка захвата: закрыть текущий дубль, сбросить состояние.
    public func captureStopped() {
        queue.async {
            if self.writer != nil {
                self.finishTake()
            }
            self.detector.reset()
            self.format = nil
            self.lastTimecode = nil
            self.videoFormatDescription = nil
            DispatchQueue.main.async {
                self.onFormatChanged?(nil)
                self.onTimecode?(nil)
            }
        }
    }

    // MARK: - вход с бэкенда (потоки захвата)

    public func handleFormat(_ newFormat: CaptureFormat) {
        queue.async {
            self.format = newFormat
            self.detector.reset()
            self.videoFormatDescription = nil
            DispatchQueue.main.async { self.onFormatChanged?(newFormat) }
        }
    }

    public func handleSignal(present: Bool) {
        DispatchQueue.main.async { self.onSignal?(present) }
    }

    public func handleFrame(pixelBuffer: CVPixelBuffer, pts: CMTime,
                     timecode rawTimecode: Timecode?, vancTrigger: VancTrigger?) {
        queue.async {
            self.processFrame(pixelBuffer: pixelBuffer, pts: pts,
                              timecode: rawTimecode, vancTrigger: vancTrigger)
        }
    }

    public func handleAudio(_ sampleBuffer: CMSampleBuffer) {
        queue.async {
            self.writer?.append(audioSampleBuffer: sampleBuffer)
        }
    }

    // MARK: - обработка (на queue)

    private func processFrame(pixelBuffer: CVPixelBuffer, pts: CMTime,
                              timecode rawTimecode: Timecode?, vancTrigger: VancTrigger?) {
        guard let format else { return }
        frameIndex += 1

        // мост может не знать fps таймкода — проставляем из формата
        var timecode = rawTimecode
        if var tc = timecode, tc.fps <= 0 {
            tc.fps = format.timecodeFPS
            timecode = tc
        }
        lastTimecode = timecode

        let mode = config.settings.detectionMode
        if mode != .manual {
            let sample = FrameSample(index: frameIndex, timecode: timecode,
                                     vancTrigger: mode == .auto ? vancTrigger : nil)
            if let event = detector.process(sample) {
                switch event {
                case .started(_, let startTC):
                    beginTake(timecode: startTC ?? timecode)
                case .stopped:
                    finishTake()
                }
            }
        }

        if let writer, !writer.append(pixelBuffer: pixelBuffer, pts: pts) {
            droppedFrames += 1
            if droppedFrames == 1 || droppedFrames % 100 == 0 {
                let count = droppedFrames
                DispatchQueue.main.async {
                    self.onError?("Dropped \(count) recording frame(s) — disk too slow")
                }
            }
        }

        enqueuePreview(pixelBuffer: pixelBuffer)
        DispatchQueue.main.async { self.onTimecode?(timecode) }
    }

    private func beginTake(timecode: Timecode?) {
        guard writer == nil, let format else { return }
        let engine = NamingEngine(template: config.settings.namingTemplate)
        let context = NamingContext(
            project: config.settings.projectName,
            date: Date(),
            scene: config.scene,
            take: config.takeNumber,
            reel: "",
            camera: config.settings.cameraLabel,
            clipName: "",
            timecode: timecode)
        let root = URL(fileURLWithPath:
            (config.settings.destinationPath as NSString).expandingTildeInPath)
        let url = root
            .appendingPathComponent(engine.relativeDirectory(for: context))
            .appendingPathComponent(engine.fileName(for: context))
            .appendingPathExtension("mov")
        do {
            writer = try TakeWriter(url: url, format: format,
                                    codec: config.settings.codec, startTimecode: timecode)
            takeStartTC = timecode
            takeStartedAt = Date()
            takeScene = config.scene
            takeNumber = config.takeNumber
            droppedFrames = 0
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
            takeNumber: takeNumber,
            startTimecode: takeStartTC,
            durationSeconds: writer.durationSeconds,
            recordedAt: takeStartedAt)
        DispatchQueue.main.async {
            self.onRecStateChanged?(false)
            self.onTakeFinished?(take)
        }
        Task {
            do {
                _ = try await writer.finish()
            } catch {
                DispatchQueue.main.async {
                    self.onError?("Failed to finalize take: \(error.localizedDescription)")
                }
            }
        }
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

        // показать немедленно, без привязки к часам плеера
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
    }
}
