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

    // UI-колбэки, вызываются на главной очереди
    public var onFormatChanged: ((CaptureFormat?) -> Void)?
    public var onTimecode: ((Timecode?) -> Void)?
    public var onRecStateChanged: ((Bool) -> Void)?
    public var onTakeFinished: ((Take) -> Void)?
    public var onSignal: ((Bool) -> Void)?
    public var onError: ((String) -> Void)?
    /// Статистика VANC-пакетов (для монитора); шлётся раз в секунду при изменениях.
    public var onVancStats: (([VancPacketStat]) -> Void)?
    /// Пиковые уровни аудиоканалов, dBFS. Приходят с частотой аудиопакетов (~25 Гц).
    public var onAudioLevels: (([Float]) -> Void)?

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
    private var takeRoll = ""
    private var takeNumber = 0
    private var videoFormatDescription: CMVideoFormatDescription?
    /// Кадры до старта записи — для пре-ролла (только пока writer == nil).
    private var preRollBuffer: [(index: Int, pixelBuffer: CVPixelBuffer, pts: CMTime)] = []
    /// Накопленная статистика VANC по (DID, SDID).
    private var vancStats: [String: VancPacketStat] = [:]
    private var vancStatsDirty = false
    private var vancStatsLastPublish = 0

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

    // MARK: - вход с бэкенда (потоки захвата)

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

    public func handleAudio(_ sampleBuffer: CMSampleBuffer) {
        queue.async {
            self.writer?.append(audioSampleBuffer: sampleBuffer)
            let levels = PCMAudio.peakLevels(of: sampleBuffer)
            if !levels.isEmpty {
                DispatchQueue.main.async { self.onAudioLevels?(levels) }
            }
        }
    }

    // MARK: - обработка (на queue)

    private func processFrame(pixelBuffer: CVPixelBuffer, pts: CMTime,
                              timecode rawTimecode: Timecode?, vancTrigger: VancTrigger?,
                              ancillaryPackets: [AncillaryPacket]) {
        guard let format else { return }
        frameIndex += 1
        updateVancStats(ancillaryPackets)
        let vancTrigger = vancTrigger ?? VancParser.recTrigger(in: ancillaryPackets)

        // мост может не знать fps таймкода — проставляем из формата
        var timecode = rawTimecode
        if var tc = timecode, tc.fps <= 0 {
            tc.fps = format.timecodeFPS
            timecode = tc
        }
        lastTimecode = timecode

        // пока не пишем — копим кадры в пре-ролл буфер (текущий кадр включительно):
        // при старте дубля из него добираются кадры от фактического начала записи
        // камеры (потерянные на дебаунсе) плюс настроенные секунды до него
        if writer == nil {
            preRollBuffer.append((index: frameIndex, pixelBuffer: pixelBuffer, pts: pts))
            let capacity = preRollCapacity
            if preRollBuffer.count > capacity {
                preRollBuffer.removeFirst(preRollBuffer.count - capacity)
            }
        }

        var startedThisFrame = false
        let mode = config.settings.detectionMode
        if mode != .manual {
            let sample = FrameSample(index: frameIndex, timecode: timecode,
                                     vancTrigger: mode == .auto ? vancTrigger : nil)
            if let event = detector.process(sample) {
                switch event {
                case .started(let atIndex, let startTC):
                    beginTake(timecode: startTC ?? timecode, recStartIndex: atIndex)
                    startedThisFrame = true // текущий кадр уже записан из буфера
                case .stopped:
                    finishTake()
                }
            }
        }

        if !startedThisFrame, let writer,
           !writer.append(pixelBuffer: pixelBuffer, pts: pts) {
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
        // публикуем не чаще ~раза в секунду, чтобы не дёргать UI на каждом кадре
        let interval = Int(format?.frameRate.rounded() ?? 25)
        if vancStatsDirty, frameIndex - vancStatsLastPublish >= interval {
            vancStatsDirty = false
            vancStatsLastPublish = frameIndex
            let stats = vancStats.values.sorted { $0.key < $1.key }
            DispatchQueue.main.async { self.onVancStats?(stats) }
        }
    }

    /// Кадров пре-ролла при текущем формате.
    private var preRollFrames: Int {
        let fps = format?.frameRate ?? 25
        return Int((config.settings.preRollSecondsEffective * fps).rounded())
    }

    /// Ёмкость буфера: пре-ролл + задержка детекции + запас.
    private var preRollCapacity: Int {
        preRollFrames + config.settings.startDebounceFrames + 25
    }

    /// Начать дубль. `recStartIndex` — кадр фактического старта записи камеры
    /// (от детектора); nil — ручной старт, пре-ролл отсчитывается от текущего кадра.
    /// Свободный URL: если файл существует, добавляет _2, _3… перед расширением.
    static func uniqueURL(for url: URL) -> URL {
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
            timecode: timecode)
        let root = URL(fileURLWithPath:
            (config.settings.destinationPath as NSString).expandingTildeInPath)
        // дубли не перезаписываются никогда: при коллизии имени — суффикс _2, _3…
        // (типовой случай: счётчик клипов начался заново, а файлы прошлой сессии
        // с теми же именами уже лежат в папке)
        let url = Self.uniqueURL(for: root
            .appendingPathComponent(engine.relativeDirectory(for: context))
            .appendingPathComponent(engine.fileName(for: context))
            .appendingPathExtension("mov"))
        do {
            let writer = try TakeWriter(
                url: url, format: format,
                codec: config.settings.codec, startTimecode: timecode,
                markerMetadata: [
                    TakeWriter.rollKey: config.roll,
                    TakeWriter.clipKey: String(config.takeNumber),
                ])
            self.writer = writer
            takeStartTC = timecode
            takeStartedAt = Date()
            takeScene = config.scene
            takeRoll = config.roll
            takeNumber = config.takeNumber
            droppedFrames = 0

            // добираем из буфера кадры от (старт камеры - пре-ролл) до текущего;
            // в Rec Run их таймкод заморожен на стартовом значении, так что
            // timecode-трек дубля остаётся корректным
            let cutoff = max(0, (recStartIndex ?? frameIndex) - preRollFrames)
            for buffered in preRollBuffer where buffered.index >= cutoff {
                writer.append(pixelBuffer: buffered.pixelBuffer, pts: buffered.pts)
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
