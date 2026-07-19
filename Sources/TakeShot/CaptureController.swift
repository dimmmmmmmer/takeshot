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
            continueClipNumbering()
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

    /// Режим сравнения лайва и плейбека.
    enum CompareMode: String, CaseIterable, Identifiable {
        case off        // только плейбек
        case wipe       // шторка
        case blend      // наложение с прозрачностью
        case sideBySide // бок о бок
        var id: String { rawValue }
    }

    @Published var compareMode: CompareMode = .off
    /// Позиция шторки (0…1, доля ширины, слева — плейбек).
    @Published var wipePosition: Double = 0.5
    /// Непрозрачность плейбека в режиме blend.
    @Published var blendOpacity: Double = 0.5
    /// Иммерсивный режим (системный фулскрин окна): только плеер и ховер-подвал.
    @Published var isImmersive = false
    /// Крупная панель аудиоканалов поверх плеера.
    @Published var showAudioPanel = false
    /// Громкость плейбека (только просмотр, на запись не влияет).
    @Published var playbackVolume: Double = 1.0 {
        didSet { player.volume = Float(playbackVolume) }
    }
    /// Отдельное фулскрин-окно плейбека (не системный фулскрин приложения).
    @Published var isPlaybackFullscreen = false
    private var playbackFullscreenWindow: NSWindow?

    /// Плеер для просмотра дублей (AVPlayerView в превью).
    let player = AVPlayer()

    // MARK: - вывод на внешний монитор

    /// Выбранный внешний дисплей (по displayID); nil — выкл.
    @Published var externalDisplayID: CGDirectDisplayID? {
        didSet {
            guard oldValue != externalDisplayID else { return }
            updateExternalWindow()
        }
    }
    private var externalWindow: NSWindow?

    struct ScreenOption: Identifiable, Equatable {
        var id: CGDirectDisplayID
        var name: String
    }

    /// Дисплеи, кроме того, на котором главное окно приложения.
    var availableScreens: [ScreenOption] {
        let currentScreen = NSApp.mainWindow?.screen
        return NSScreen.screens.compactMap { screen in
            guard screen != currentScreen,
                  let id = screen.deviceDescription[
                      NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            else { return nil }
            return ScreenOption(id: id, name: screen.localizedName)
        }
    }

    private func updateExternalWindow() {
        externalWindow?.orderOut(nil)
        externalWindow = nil
        pipeline.externalMirrorEnabled = false

        guard let displayID = externalDisplayID,
              let screen = NSScreen.screens.first(where: {
                  ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                   as? CGDirectDisplayID) == displayID
              }) else { return }

        pipeline.externalMirrorEnabled = true
        let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false, screen: screen)
        window.level = .statusBar
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenAuxiliary, .stationary]
        window.contentView = NSHostingView(rootView:
            ExternalOutputView().environmentObject(self))
        window.setFrame(screen.frame, display: true)
        window.orderFront(nil)
        externalWindow = window
    }

    /// Системный фулскрин главного окна (иммерсивный режим).
    func toggleFullscreen() {
        NSApp.mainWindow?.toggleFullScreen(nil)
    }

    /// Фулскрин ТОЛЬКО плейбека: безрамочное окно на весь экран,
    /// приложение при этом остаётся как было (это не зелёная кнопка).
    func togglePlaybackFullscreen() {
        if isPlaybackFullscreen {
            playbackFullscreenWindow?.orderOut(nil)
            playbackFullscreenWindow = nil
            isPlaybackFullscreen = false
            return
        }
        guard let screen = NSApp.mainWindow?.screen ?? NSScreen.main else { return }
        let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false, screen: screen)
        window.level = .statusBar
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView:
            PlaybackFullscreenView().environmentObject(self))
        window.setFrame(screen.frame, display: true)
        window.makeKeyAndOrderFront(nil)
        playbackFullscreenWindow = window
        isPlaybackFullscreen = true
    }

    // MARK: - аудиоканалы (маска записи)

    /// Включён ли канал в запись.
    func isChannelEnabled(_ index: Int) -> Bool {
        guard let mask = settings.audioChannelMask else { return true }
        return mask & (1 << index) != 0
    }

    func toggleAudioChannel(_ index: Int) {
        var mask = settings.audioChannelMask ?? 0xFFFF
        mask ^= (1 << index)
        // все включены — храним nil (= «все», в т.ч. если каналов станет больше)
        settings.audioChannelMask = (mask & 0xFFFF) == 0xFFFF ? nil : mask
    }

    /// Аудиовыход плейбека.
    var playbackOutputUID: String? {
        get { settings.playbackAudioDeviceUID }
        set {
            settings.playbackAudioDeviceUID = newValue
            player.audioOutputDeviceUniqueID = newValue
        }
    }

    /// Открыть файл в плеере и переключиться в режим плейбека.
    /// Фото просто показываются (AVPlayer для них не нужен).
    func play(url: URL) {
        playbackURL = url
        if Self.imageExtensions.contains(url.pathExtension.lowercased()) {
            player.pause()
            player.replaceCurrentItem(with: nil)
        } else {
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
            player.play()
        }
        viewerMode = .playback
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
        player.audioOutputDeviceUniqueID = stored.playbackAudioDeviceUID
        bindPipeline()
        refreshDevices() // выбор первого устройства запустит захват через didSet
        startFolderSync()

        // иммерсив включается/выключается системным фулскрином главного окна
        NotificationCenter.default.addObserver(
            forName: NSWindow.didEnterFullScreenNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard (note.object as? NSWindow)?.styleMask.contains(.titled) == true else { return }
            Task { @MainActor [weak self] in self?.isImmersive = true }
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didExitFullScreenNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard (note.object as? NSWindow)?.styleMask.contains(.titled) == true else { return }
            Task { @MainActor [weak self] in self?.isImmersive = false }
        }
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

    /// Цвет подложки плеера; по умолчанию — миддл-грей (18% серый).
    var playerBackground: Color {
        get {
            settings.playerBackgroundHex.flatMap(Color.init(hex:))
                ?? Color(hex: "#7F7F7F")!
        }
        set { settings.playerBackgroundHex = newValue.hexString }
    }

    /// Цвет фона окна; по умолчанию ~полторы ступени ниже миддл-грея.
    var appBackground: Color {
        get {
            settings.appBackgroundHex.flatMap(Color.init(hex:))
                ?? Color(hex: "#464646")!
        }
        set { settings.appBackgroundHex = newValue.hexString }
    }

    // MARK: - степперы полей нейминга

    func stepRoll(_ delta: Int) {
        roll = FieldStepper.stepTrailingNumber(roll, by: delta)
    }

    func stepCamera(_ delta: Int) {
        settings.cameraLabel = FieldStepper.stepLetter(settings.cameraLabel, by: delta)
    }

    /// Хоткей: поставить/снять оценку последнему дублю.
    func toggleLastRating(_ rating: TakeRating) {
        guard let last = takes.last else { return }
        setRating(last.rating == rating ? .none : rating, for: last)
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

    /// Пути, уже проверенные на метку TakeShot (чтобы не читать мету повторно).
    private var scannedPaths: Set<String> = []

    private func scanDestinationFolder() {
        let root = destinationRoot
        let ownTakePaths = Set(takes.map { $0.url.path })
        Task.detached(priority: .utility) { [weak self] in
            let candidates = Self.findForeignVideos(root: root, excluding: ownTakePaths)
            await self?.classifyFoundFiles(candidates)
        }
    }

    /// Наши файлы (метка com.takeshot.origin в QuickTime-мете) возвращаются
    /// в список дублей после перезапуска; остальные — Other content.
    private func classifyFoundFiles(_ candidates: [URL]) async {
        var restored: [Take] = []
        var foreign: [URL] = []
        let ratings = (try? String(contentsOf: takeLogURL, encoding: .utf8))
            .map(TakeLogExporter.parseRatings(csv:)) ?? [:]

        for url in candidates {
            if scannedPaths.contains(url.path) {
                if !takes.contains(where: { $0.url.path == url.path }) {
                    foreign.append(url)
                }
                continue
            }
            let ext = url.pathExtension.lowercased()
            guard ext == "mov" || ext == "mp4" else {
                scannedPaths.insert(url.path)
                foreign.append(url)
                continue
            }
            let asset = AVURLAsset(url: url)
            let metadata = (try? await asset.load(.metadata)) ?? []
            func value(_ key: String) -> String? {
                metadata.first { ($0.key as? String) == key }?.stringValue
            }
            scannedPaths.insert(url.path)
            guard value(TakeWriter.markerKey) != nil else {
                foreign.append(url)
                continue
            }
            let duration = (try? await asset.load(.duration))?.seconds ?? 0
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?
                .creationDate ?? Date.distantPast
            let take = Take(
                url: url,
                displayName: url.deletingPathExtension().lastPathComponent,
                scene: "",
                roll: value(TakeWriter.rollKey) ?? "",
                takeNumber: Int(value(TakeWriter.clipKey) ?? "") ?? 0,
                startTimecode: nil,
                durationSeconds: duration,
                rating: ratings[url.lastPathComponent] ?? .none,
                recordedAt: created)
            restored.append(take)
        }

        if !restored.isEmpty {
            let known = Set(takes.map { $0.url.path })
            let new = restored.filter { !known.contains($0.url.path) }
            if !new.isEmpty {
                takes.append(contentsOf: new)
                takes.sort { $0.recordedAt < $1.recordedAt }
                for take in new {
                    generateThumbnail(for: take)
                }
                continueClipNumbering()
            }
        }
        let sorted = foreign.sorted { $0.lastPathComponent < $1.lastPathComponent }
        if otherFiles != sorted {
            otherFiles = sorted
            generateOtherThumbnails(for: sorted)
        }
    }

    /// Номер следующего клипа — после максимального в текущем ролле.
    private func continueClipNumbering() {
        let maxClip = takes.filter { $0.roll == roll }.map(\.takeNumber).max() ?? 0
        nextTakeNumber = maxClip + 1
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
