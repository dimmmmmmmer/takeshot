import AppKit
import AVFoundation
import CaptureCore
import Combine
import CoreMedia
import CoreVideo
import Foundation

/// UI-состояние приложения. Тяжёлая работа с кадрами живёт в CapturePipeline;
/// контроллер только гоняет конфигурацию туда и события обратно.
@MainActor
final class CaptureController: ObservableObject {
    @Published var devices: [CaptureDeviceInfo] = []
    /// Захват стартует автоматически при выборе устройства — отдельной кнопки нет.
    @Published var selectedDeviceID: String? {
        didSet {
            guard oldValue != selectedDeviceID else { return }
            restartCapture()
        }
    }
    @Published var isCapturing = false
    @Published var isRecording = false
    @Published var signalPresent = true
    @Published var signalFormat: CaptureFormat?
    @Published var currentTimecode: Timecode?
    @Published var takes: [Take] = []
    /// Превью-кадры дублей для режима миниатюр.
    @Published var thumbnails: [Take.ID: NSImage] = [:]
    @Published var scene: String = "1" {
        didSet { pushConfig() }
    }
    @Published var nextTakeNumber: Int = 1 {
        didSet { pushConfig() }
    }
    @Published var lastError: String?
    @Published var mockCameraRecording = false
    @Published var settings = CaptureSettings.loaded() {
        didSet {
            settings.save()
            pushConfig()
            L10n.apply(appLanguage)
        }
    }

    /// Язык интерфейса; по умолчанию английский.
    var appLanguage: AppLanguage {
        get { settings.appLanguage.flatMap(AppLanguage.init(rawValue:)) ?? .english }
        set { settings.appLanguage = newValue.rawValue }
    }

    let pipeline: CapturePipeline

    private let backend: AggregateBackend

    var backendAvailable: Bool { backend.isAvailable }

    /// Выбран ли демо-источник (для показа кнопки «REC демо-камеры»).
    var isMockSelected: Bool {
        selectedDeviceID?.hasPrefix("mock:") ?? false
    }

    init(extraBackends: [(String, CaptureBackend)] = []) {
        var children: [(String, CaptureBackend)] = [
            ("decklink", DeckLinkBackendAdapter()),
            ("mock", MockCaptureBackend()),
        ]
        children.append(contentsOf: extraBackends)
        let backend = AggregateBackend(children: children)
        self.backend = backend

        let stored = CaptureSettings.loaded()
        self.pipeline = CapturePipeline(config: .init(
            settings: stored, scene: "1", takeNumber: 1))

        backend.delegate = self
        L10n.apply(stored.appLanguage.flatMap(AppLanguage.init(rawValue:)) ?? .english)
        bindPipeline()
        refreshDevices() // выбор первого устройства запустит захват через didSet
    }

    private func bindPipeline() {
        pipeline.onFormatChanged = { [weak self] format in
            self?.signalFormat = format
        }
        pipeline.onTimecode = { [weak self] timecode in
            self?.currentTimecode = timecode
        }
        pipeline.onRecStateChanged = { [weak self] recording in
            self?.isRecording = recording
        }
        pipeline.onTakeFinished = { [weak self] take in
            guard let self else { return }
            self.takes.append(take)
            self.nextTakeNumber += 1
            self.exportTakeLog()
            self.generateThumbnail(for: take)
        }
        pipeline.onSignal = { [weak self] present in
            self?.signalPresent = present
        }
        pipeline.onError = { [weak self] message in
            self?.lastError = message
        }
    }

    private func pushConfig() {
        pipeline.update(config: .init(
            settings: settings, scene: scene, takeNumber: nextTakeNumber))
    }

    // MARK: - управление захватом

    func refreshDevices() {
        devices = backend.devices()

        let realDevices = devices.filter { !$0.id.hasPrefix("mock:") }
        if let selected = selectedDeviceID, !devices.contains(where: { $0.id == selected }) {
            // выбранное устройство выдернули — откатываемся на первое доступное
            lastError = L("device_disconnected")
            selectedDeviceID = devices.first?.id
        } else if selectedDeviceID == nil || (isMockSelected && !realDevices.isEmpty) {
            // ничего не выбрано, или выбран демо-источник, а появилась настоящая
            // плата — переключаемся на неё (захват стартует сам через didSet)
            selectedDeviceID = realDevices.first?.id ?? devices.first?.id
        }
    }

    func startCapture() {
        guard let deviceID = selectedDeviceID else { return }
        do {
            try backend.startCapture(deviceID: deviceID)
            isCapturing = true
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stopCapture() {
        backend.stopCapture()
        pipeline.captureStopped()
        isCapturing = false
        if isMockSelected {
            mockCameraRecording = false
        }
    }

    private func restartCapture() {
        if isCapturing {
            stopCapture()
        }
        startCapture()
    }

    func toggleManualRecord() {
        pipeline.toggleManualRecord()
    }

    /// «Нажать REC на камере» демо-источника: TC побежит/встанет,
    /// авто-детекция должна поймать это как настоящий дубль.
    func toggleMockCameraRecord() {
        mockCameraRecording.toggle()
        backend.child(of: MockCaptureBackend.self)?
            .setCameraRecording(mockCameraRecording)
    }

    func toggleCircle(_ take: Take) {
        guard let idx = takes.firstIndex(of: take) else { return }
        takes[idx].isCircled.toggle()
        exportTakeLog()
    }

    /// URL журнала метадаты (для «показать в Finder»).
    var takeLogURL: URL {
        destinationRoot.appendingPathComponent(TakeLogExporter.fileName)
    }

    private var destinationRoot: URL {
        URL(fileURLWithPath: (settings.destinationPath as NSString).expandingTildeInPath)
    }

    /// Resolve-совместимый CSV: пишется заново при каждом дубле и каждой отметке
    /// circle take — в Резолве импортируется через Media Pool → Import Metadata.
    private func exportTakeLog() {
        let takes = takes
        let root = destinationRoot
        Task.detached(priority: .utility) {
            try? TakeLogExporter.write(takes: takes, toDirectory: root)
        }
    }

    /// Кадр-превью из записанного файла; файл финализируется асинхронно,
    /// поэтому несколько попыток с паузой.
    private func generateThumbnail(for take: Take) {
        Task.detached(priority: .utility) { [weak self] in
            for _ in 0..<10 {
                if FileManager.default.fileExists(atPath: take.url.path) {
                    let asset = AVURLAsset(url: take.url)
                    let generator = AVAssetImageGenerator(asset: asset)
                    generator.appliesPreferredTrackTransform = true
                    generator.maximumSize = CGSize(width: 480, height: 480)
                    let time = CMTime(seconds: min(1.0, take.durationSeconds / 2),
                                      preferredTimescale: 600)
                    if let (cgImage, _) = try? await generator.image(at: time) {
                        let image = NSImage(cgImage: cgImage,
                                            size: NSSize(width: cgImage.width,
                                                         height: cgImage.height))
                        await MainActor.run { [weak self] in
                            self?.thumbnails[take.id] = image
                        }
                        return
                    }
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }
}

// MARK: - CaptureBackendDelegate (колбэки с потоков захвата — сразу в конвейер)

extension CaptureController: CaptureBackendDelegate {
    nonisolated func backend(_ backend: CaptureBackend, didDetectFormat format: CaptureFormat) {
        pipeline.handleFormat(format)
    }

    nonisolated func backend(_ backend: CaptureBackend, didReceiveFrame pixelBuffer: CVPixelBuffer,
                             pts: CMTime, timecode: Timecode?, vancTrigger: VancTrigger?) {
        pipeline.handleFrame(pixelBuffer: pixelBuffer, pts: pts,
                             timecode: timecode, vancTrigger: vancTrigger)
    }

    nonisolated func backend(_ backend: CaptureBackend, didReceiveAudio sampleBuffer: CMSampleBuffer) {
        pipeline.handleAudio(sampleBuffer)
    }

    nonisolated func backend(_ backend: CaptureBackend, signalPresent: Bool) {
        pipeline.handleSignal(present: signalPresent)
    }

    nonisolated func backendDeviceListChanged(_ backend: CaptureBackend) {
        Task { @MainActor in
            self.refreshDevices()
        }
    }
}
