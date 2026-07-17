import AVFoundation
import CaptureCore
import Combine
import CoreMedia
import CoreVideo
import Foundation

/// Центральный контроллер приложения: связывает капчур-бэкенд, детектор REC,
/// запись дублей и UI-состояние.
@MainActor
final class CaptureController: ObservableObject {
    // MARK: - UI-состояние

    @Published var devices: [CaptureDeviceInfo] = []
    @Published var selectedDeviceID: String?
    @Published var isCapturing = false
    @Published var isRecording = false
    @Published var signalFormat: CaptureFormat?
    @Published var currentTimecode: Timecode?
    @Published var takes: [Take] = []
    @Published var scene: String = "1"
    @Published var nextTakeNumber: Int = 1
    @Published var lastError: String?
    @Published var settings = CaptureSettings.loaded() {
        didSet { settings.save() }
    }

    var backendAvailable: Bool { backend.isAvailable }

    // MARK: - внутренности

    private let backend: CaptureBackend
    private var detector: RecDetector
    private var writer: TakeWriter?
    private var frameIndex = 0
    private var currentTakeStartTC: Timecode?
    private var currentTakeStartedAt = Date()

    init(backend: CaptureBackend = DeckLinkBackendAdapter()) {
        self.backend = backend
        let stored = CaptureSettings.loaded()
        self.detector = RecDetector(config: RecDetectorConfig(
            startDebounceFrames: stored.startDebounceFrames,
            stopDebounceFrames: stored.stopDebounceFrames))
        backend.delegate = self
        refreshDevices()
    }

    func refreshDevices() {
        devices = backend.devices()
        if selectedDeviceID == nil {
            selectedDeviceID = devices.first?.id
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
        isCapturing = false
        if isRecording {
            finishCurrentTake(atIndex: frameIndex)
        }
    }

    /// Ручной REC (режим manual или дублирующая кнопка).
    func toggleManualRecord() {
        if isRecording {
            finishCurrentTake(atIndex: frameIndex)
        } else {
            beginTake(timecode: currentTimecode)
        }
    }

    func toggleCircle(_ take: Take) {
        guard let idx = takes.firstIndex(of: take) else { return }
        takes[idx].isCircled.toggle()
    }

    // MARK: - жизненный цикл дубля

    private func beginTake(timecode: Timecode?) {
        guard writer == nil, let format = signalFormat else { return }
        let context = namingContext(timecode: timecode)
        let engine = NamingEngine(template: settings.namingTemplate)
        let dir = URL(fileURLWithPath: (settings.destinationPath as NSString).expandingTildeInPath)
            .appendingPathComponent(engine.relativeDirectory(for: context))
        let url = dir.appendingPathComponent(engine.fileName(for: context))
            .appendingPathExtension("mov")
        do {
            writer = try TakeWriter(url: url, format: format,
                                    codec: settings.codec, startTimecode: timecode)
            currentTakeStartTC = timecode
            currentTakeStartedAt = Date()
            isRecording = true
            lastError = nil
        } catch {
            lastError = "Не удалось начать запись: \(error.localizedDescription)"
        }
    }

    private func finishCurrentTake(atIndex index: Int) {
        guard let writer else {
            isRecording = false
            return
        }
        self.writer = nil
        isRecording = false
        let take = Take(
            url: writer.url,
            displayName: writer.url.deletingPathExtension().lastPathComponent,
            scene: scene,
            takeNumber: nextTakeNumber,
            startTimecode: currentTakeStartTC,
            durationSeconds: writer.durationSeconds,
            recordedAt: currentTakeStartedAt)
        takes.append(take)
        nextTakeNumber += 1
        Task {
            do {
                _ = try await writer.finish()
            } catch {
                await MainActor.run {
                    self.lastError = "Ошибка записи дубля: \(error.localizedDescription)"
                }
            }
        }
    }

    private func namingContext(timecode: Timecode?) -> NamingContext {
        NamingContext(
            project: settings.projectName,
            date: Date(),
            scene: scene,
            take: nextTakeNumber,
            reel: "",
            camera: settings.cameraLabel,
            clipName: "",
            timecode: timecode)
    }
}

// MARK: - CaptureBackendDelegate (колбэки с потока захвата)

extension CaptureController: CaptureBackendDelegate {
    nonisolated func backend(_ backend: CaptureBackend, didDetectFormat format: CaptureFormat) {
        Task { @MainActor in
            self.signalFormat = format
            self.detector.reset()
        }
    }

    nonisolated func backend(_ backend: CaptureBackend, didReceiveFrame pixelBuffer: CVPixelBuffer,
                             pts: CMTime, timecode: Timecode?, vancTrigger: VancTrigger?) {
        Task { @MainActor in
            self.handleFrame(pixelBuffer: pixelBuffer, pts: pts,
                             timecode: timecode, vancTrigger: vancTrigger)
        }
    }

    nonisolated func backend(_ backend: CaptureBackend, didReceiveAudio sampleBuffer: CMSampleBuffer) {
        Task { @MainActor in
            self.writer?.append(audioSampleBuffer: sampleBuffer)
        }
    }

    nonisolated func backend(_ backend: CaptureBackend, signalPresent: Bool) {
        Task { @MainActor in
            if !signalPresent { self.currentTimecode = nil }
        }
    }

    nonisolated func backendDeviceListChanged(_ backend: CaptureBackend) {
        Task { @MainActor in
            self.refreshDevices()
        }
    }

    private func handleFrame(pixelBuffer: CVPixelBuffer, pts: CMTime,
                             timecode: Timecode?, vancTrigger: VancTrigger?) {
        frameIndex += 1
        currentTimecode = timecode

        if settings.detectionMode != .manual {
            let sample = FrameSample(index: frameIndex, timecode: timecode,
                                     vancTrigger: settings.detectionMode == .auto ? vancTrigger : nil)
            if let event = detector.process(sample) {
                switch event {
                case .started(_, let tc):
                    beginTake(timecode: tc ?? timecode)
                case .stopped(let index):
                    finishCurrentTake(atIndex: index)
                }
            }
        }

        writer?.append(pixelBuffer: pixelBuffer, pts: pts)
    }
}
