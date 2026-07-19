import AppKit
import AVFoundation
import CaptureCore
import Combine
import CoreMedia
import CoreVideo
import Foundation
import SwiftUI

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
    /// Статистика VANC-пакетов для окна монитора.
    @Published var vancStats: [VancPacketStat] = []
    /// Ролл (катушка/носитель). Смена ролла сбрасывает номер клипа.
    @Published var roll: String = "001" {
        didSet {
            guard oldValue != roll else { return }
            if nextTakeNumber != 1 { nextTakeNumber = 1 }
            pushConfig()
        }
    }
    @Published var nextTakeNumber: Int = 1 {
        didSet { pushConfig() }
    }
    /// Видео и фото в папке записи, появившиеся не из TakeShot (сброшены руками).
    @Published var otherFiles: [URL] = []
    /// Миниатюры для Other content.
    @Published var otherThumbnails: [URL: NSImage] = [:]
    @Published var lastError: String?
    /// Пиковые уровни аудиоканалов, dBFS (для метров).
    @Published var audioLevels: [Float] = []
    /// Режим просмотра: живой сигнал или плейбек записанного.
    @Published var viewerMode: ViewerMode = .record {
        didSet {
            if viewerMode == .record {
                player.pause()
            }
        }
    }
    /// Что сейчас загружено в плеер (для подсветки в списке).
    @Published var playbackURL: URL?

    enum ViewerMode: String, CaseIterable {
        case record
        case playback
    }

    /// Плеер для просмотра дублей (AVPlayerView в превью).
    let player = AVPlayer()

    /// Открыть файл в плеере и переключиться в режим плейбека.
    func play(url: URL) {
        playbackURL = url
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        viewerMode = .playback
        player.play()
    }
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
        // демо-источник всегда в конце списка; при появлении реальной платы
        // приложение само переключится на неё (см. refreshDevices)
        var children: [(String, CaptureBackend)] = [
            ("decklink", DeckLinkBackendAdapter()),
            ("mock", MockCaptureBackend()),
        ]
        children.append(contentsOf: extraBackends)
        let backend = AggregateBackend(children: children)
        self.backend = backend

        let stored = CaptureSettings.loaded()
        self.pipeline = CapturePipeline(config: .init(
            settings: stored, roll: "001", takeNumber: 1))

        backend.delegate = self
        L10n.apply(stored.appLanguage.flatMap(AppLanguage.init(rawValue:)) ?? .english)
        bindPipeline()
        refreshDevices() // выбор первого устройства запустит захват через didSet
        startFolderSync()
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
        pipeline.onVancStats = { [weak self] stats in
            self?.vancStats = stats
        }
        pipeline.onAudioLevels = { [weak self] levels in
            self?.audioLevels = levels
        }
    }

    /// Тема интерфейса из настроек.
    var colorScheme: ColorScheme? {
        switch settings.appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    /// Цвет подложки плеера.
    var playerBackground: Color {
        get { settings.playerBackgroundHex.flatMap(Color.init(hex:)) ?? .black }
        set { settings.playerBackgroundHex = newValue.hexString }
    }

    /// Оценка последнего дубля по хоткею (цикл: нет → good → bad → нет).
    func circleLastTake() {
        guard let last = takes.last else { return }
        cycleRating(last)
    }

    private func pushConfig() {
        pipeline.update(config: .init(
            settings: settings, roll: roll, takeNumber: nextTakeNumber))
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

    /// Клик по кружку: нет → good → bad → нет.
    func cycleRating(_ take: Take) {
        guard let idx = takes.firstIndex(of: take) else { return }
        switch takes[idx].rating {
        case .none: takes[idx].rating = .good
        case .good: takes[idx].rating = .bad
        case .bad: takes[idx].rating = .none
        }
        exportTakeLog()
    }

    func setRating(_ rating: TakeRating, for take: Take) {
        guard let idx = takes.firstIndex(of: take) else { return }
        takes[idx].rating = rating
        exportTakeLog()
    }

    /// URL журнала метадаты (для «показать в Finder»).
    var takeLogURL: URL {
        destinationRoot.appendingPathComponent(TakeLogExporter.fileName)
    }

    /// Корневая папка записи (для кнопки «открыть папку»).
    var destinationRoot: URL {
        URL(fileURLWithPath: (settings.destinationPath as NSString).expandingTildeInPath)
    }

    func openDestinationInFinder() {
        try? FileManager.default.createDirectory(at: destinationRoot,
                                                 withIntermediateDirectories: true)
        NSWorkspace.shared.open(destinationRoot)
    }

    /// Диалог смены папки записи (используется и из настроек, и из нижней панели).
    func chooseDestinationFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = destinationRoot
        if panel.runModal() == .OK, let url = panel.url {
            settings.destinationPath = url.path
        }
    }

    // MARK: - синхронизация папки (Other content)

    nonisolated private static let videoExtensions: Set<String> = ["mov", "mp4", "mxf", "m4v", "avi"]
    nonisolated private static let imageExtensions: Set<String> =
        ["jpg", "jpeg", "png", "heic", "tif", "tiff", "dng", "arw", "cr2", "webp"]

    /// Лёгкий поллинг папки записи: видеофайлы, которых нет среди наших дублей,
    /// показываются отдельным блоком Other content.
    private func startFolderSync() {
        Task { [weak self] in
            while let self, !Task.isCancelled {
                self.scanDestinationFolder()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func scanDestinationFolder() {
        let root = destinationRoot
        let ownTakePaths = Set(takes.map { $0.url.path })
        Task.detached(priority: .utility) { [weak self] in
            let sorted = Self.findForeignVideos(root: root, excluding: ownTakePaths)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if self.otherFiles != sorted {
                    self.otherFiles = sorted
                    self.generateOtherThumbnails(for: sorted)
                }
            }
        }
    }

    /// Миниатюры для Other content: фото — напрямую, видео — через генератор кадров.
    private func generateOtherThumbnails(for urls: [URL]) {
        let missing = urls.filter { otherThumbnails[$0] == nil }
        guard !missing.isEmpty else { return }
        Task.detached(priority: .utility) { [weak self] in
            for url in missing {
                var image: NSImage?
                let ext = url.pathExtension.lowercased()
                if Self.imageExtensions.contains(ext) {
                    if let source = NSImage(contentsOf: url) {
                        image = source
                    }
                } else {
                    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                    generator.appliesPreferredTrackTransform = true
                    generator.maximumSize = CGSize(width: 480, height: 480)
                    if let (cgImage, _) = try? await generator.image(
                        at: CMTime(seconds: 0.5, preferredTimescale: 600)) {
                        image = NSImage(cgImage: cgImage,
                                        size: NSSize(width: cgImage.width,
                                                     height: cgImage.height))
                    }
                }
                if let image {
                    await MainActor.run { [weak self] in
                        self?.otherThumbnails[url] = image
                    }
                }
            }
        }
    }

    nonisolated private static func findForeignVideos(root: URL,
                                                      excluding ownPaths: Set<String>) -> [URL] {
        var found: [URL] = []
        let cutoff = Date().addingTimeInterval(-3) // пишущиеся файлы не трогаем
        if let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let url as URL in enumerator {
                let ext = url.pathExtension.lowercased()
                guard videoExtensions.contains(ext) || imageExtensions.contains(ext),
                      !ownPaths.contains(url.path) else { continue }
                let modified = (try? url.resourceValues(
                    forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let modified, modified > cutoff { continue }
                found.append(url)
            }
        }
        return found.sorted { $0.lastPathComponent < $1.lastPathComponent }
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
                             pts: CMTime, timecode: Timecode?, vancTrigger: VancTrigger?,
                             ancillaryPackets: [AncillaryPacket]) {
        pipeline.handleFrame(pixelBuffer: pixelBuffer, pts: pts,
                             timecode: timecode, vancTrigger: vancTrigger,
                             ancillaryPackets: ancillaryPackets)
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
