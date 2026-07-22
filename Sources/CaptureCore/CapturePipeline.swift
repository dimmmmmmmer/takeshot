import AVFoundation
import CoreImage
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
    /// Второй слой — для вывода на внешний монитор. Кадры зеркалируются,
    /// только когда externalMirrorEnabled == true (копия — копеечная).
    public let externalLayer = AVSampleBufferDisplayLayer()
    public var externalMirrorEnabled = false
    /// Третий слой — фулскрин-окно лайва (плеер на весь экран).
    public let fullscreenLayer = AVSampleBufferDisplayLayer()
    public var fullscreenMirrorEnabled = false

    // LUT (все обращения — на queue)
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var lutFilter: CIFilter?
    private var lutName: String?
    private var lutPreview = false
    private var lutRecord = false
    private var lutIntensity: Double = 1
    private var lutPool: CVPixelBufferPool?
    private var lutPoolWidth = 0
    private var lutPoolHeight = 0

    /// Установить LUT (nil — выключить), режимы применения и интенсивность (0…1).
    public func setLUT(_ lut: CubeLUT?, preview: Bool, record: Bool,
                       intensity: Double = 1) {
        queue.async {
            self.lutFilter = lut?.makeFilter()
            self.lutName = lut?.name
            self.lutPreview = preview && lut != nil
            self.lutRecord = record && lut != nil
            self.lutIntensity = min(1, max(0, intensity))
            self.lutPool = nil
        }
    }

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
    /// Незавершённые задачи финализации файлов (ждём их при остановке/выходе).
    private var pendingFinishTasks: [Task<Void, Never>] = []

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

    private var trimFormatCache: CMAudioFormatDescription?
    /// Число каналов входного аудио (кэшируется и во время превью — чтобы writer
    /// знал формат аудио-входа заранее, до первого пакета записи).
    private var sourceAudioChannels = 0

    public func handleAudio(_ sampleBuffer: CMSampleBuffer) {
        queue.async {
            let levels = PCMAudio.peakLevels(of: sampleBuffer)
            self.sourceAudioChannels = levels.count
            // метры показывают ВСЕ каналы; в файл идут только включённые в маске
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

    /// Сколько каналов реально пишется в файл при текущей маске.
    private var recordChannelCount: Int {
        guard sourceAudioChannels > 0 else { return 0 }
        guard let mask = config.settings.audioChannelMask else { return sourceAudioChannels }
        return (0..<sourceAudioChannels).filter { mask & (1 << $0) != 0 }.count
    }

    // MARK: - обработка (на queue)

    /// Колориметрия по пресету настроек: "709" (nclc 1-1-1, дефолт) / "601" / "2020".
    public static func colorTagValues(for preset: String?)
        -> (primaries: CFString, transfer: CFString, matrix: CFString) {
        switch preset {
        case "601":
            return (kCVImageBufferColorPrimaries_SMPTE_C,
                    kCVImageBufferTransferFunction_ITU_R_709_2,
                    kCVImageBufferYCbCrMatrix_ITU_R_601_4)
        case "2020":
            return (kCVImageBufferColorPrimaries_ITU_R_2020,
                    kCVImageBufferTransferFunction_ITU_R_2020,
                    kCVImageBufferYCbCrMatrix_ITU_R_2020)
        default:
            return (kCVImageBufferColorPrimaries_ITU_R_709_2,
                    kCVImageBufferTransferFunction_ITU_R_709_2,
                    kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        }
    }

    /// Проставить кадру колориметрию из настроек, если бэкенд её не сообщил.
    /// Без тегов превью-слой и плеер интерпретируют цвет по-разному.
    private func tagColorIfUntagged(_ pixelBuffer: CVPixelBuffer) {
        guard CVBufferGetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey,
                                    nil) == nil else { return }
        let tags = Self.colorTagValues(for: config.settings.colorTagPreset)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey,
                              tags.primaries, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey,
                              tags.transfer, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey,
                              tags.matrix, .shouldPropagate)
    }

    private func processFrame(pixelBuffer: CVPixelBuffer, pts: CMTime,
                              timecode rawTimecode: Timecode?, vancTrigger: VancTrigger?,
                              ancillaryPackets: [AncillaryPacket]) {
        guard let format else { return }
        tagColorIfUntagged(pixelBuffer)
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

        // LUT: превью может быть с лутом, запись — чистой (или наоборот)
        let displayBuffer = lutPreview
            ? (applyLUT(to: pixelBuffer) ?? pixelBuffer) : pixelBuffer
        let recordBuffer = lutRecord
            ? (lutPreview ? displayBuffer : (applyLUT(to: pixelBuffer) ?? pixelBuffer))
            : pixelBuffer

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
           !writer.append(pixelBuffer: recordBuffer, pts: pts) {
            droppedFrames += 1
            if droppedFrames == 1 || droppedFrames % 100 == 0 {
                let count = droppedFrames
                DispatchQueue.main.async {
                    self.onError?("Dropped \(count) recording frame(s) — disk too slow")
                }
            }
        }

        enqueuePreview(pixelBuffer: displayBuffer)
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

    /// Ёмкость буфера: пре-ролл + задержка детекции + запас, но с потолком по
    /// памяти. Без потолка 3 с пре-ролла на 4К60 держат ~6 ГБ несжатых кадров
    /// в RAM (OOM); при высоком разрешении пре-ролл тихо укорачивается.
    private var preRollCapacity: Int {
        let wanted = preRollFrames + config.settings.startDebounceFrames + 25
        guard let format, format.width > 0, format.height > 0 else { return wanted }
        let bytesPerFrame = format.width * format.height * 4
        let budgetBytes = 1_500_000_000 // ~1.5 ГБ
        let byteCap = max(config.settings.startDebounceFrames + 5,
                          budgetBytes / max(1, bytesPerFrame))
        return min(wanted, byteCap)
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
            clipPadding: config.settings.clipPadWidthEffective,
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
                markerMetadata: {
                    var meta = [
                        TakeWriter.rollKey: config.roll,
                        TakeWriter.clipKey: String(config.takeNumber),
                    ]
                    // файл с запечённым лутом помечаем: плейбек не наложит LUT повторно
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

            // добираем из буфера кадры от (старт камеры - пре-ролл) до текущего;
            // в Rec Run их таймкод заморожен на стартовом значении, так что
            // timecode-трек дубля остаётся корректным
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
        // задачу финализации трекаем — чтобы дождаться её при остановке захвата
        // и выходе из приложения (иначе файл может остаться недописанным)
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

    /// Дождаться финализации всех дописываемых файлов (стоп захвата, выход).
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

    /// Прогнать кадр через LUT (CoreImage, GPU). nil — если LUT не настроен/ошибка.
    private func applyLUT(to pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        guard let filter = lutFilter else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        if lutPool == nil || lutPoolWidth != width || lutPoolHeight != height {
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary,
                                    &lutPool)
            lutPoolWidth = width
            lutPoolHeight = height
        }
        guard let pool = lutPool else { return nil }
        var outBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &outBuffer)
        guard let outBuffer else { return nil }

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

    /// Смешать оригинал и LUT'нутый кадр по интенсивности (кросс-дизолв).
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
