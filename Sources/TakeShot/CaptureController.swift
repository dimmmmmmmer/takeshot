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
            refreshNameCollision()
        }
    }
    @Published var nextTakeNumber: Int = 1 {
        didSet {
            pushConfig()
            refreshNameCollision()
        }
    }
    /// Имя файла, которое даст текущая комбинация нейминга, уже существует в папке.
    /// nil — коллизии нет. Предупреждаем оператора ДО записи (степпер прыгнул на
    /// занятый номер, ролл вернули назад и т.п.); писать поверх мы всё равно не будем.
    @Published var nameCollision: String?
    /// Видео и фото в папке записи, появившиеся не из TakeShot (сброшены руками).
    @Published var otherFiles: [URL] = []
    /// Миниатюры для Other content.
    @Published var otherThumbnails: [URL: NSImage] = [:]
    /// Длительности видео в Other content (сек).
    @Published var otherDurations: [URL: Double] = [:]
    /// Ошибка-тост: всплывает над подвалом и сама исчезает через несколько секунд.
    @Published var lastError: String? {
        didSet {
            errorDismissTask?.cancel()
            guard lastError != nil else { return }
            errorDismissTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                self?.lastError = nil
            }
        }
    }
    private var errorDismissTask: Task<Void, Never>?
    /// Пиковые уровни аудиоканалов, dBFS (для метров).
    @Published var audioLevels: [Float] = []
    /// Режим просмотра: живой сигнал или плейбек записанного.
    @Published var viewerMode: ViewerMode = .record {
        didSet {
            if viewerMode == .record {
                player.pause()
            }
            updateTapRunning()
        }
    }

    /// Опрос кадров плейбека нужен только когда просмотр реально виден.
    private func updateTapRunning() {
        let videoLoaded = playbackURL.map {
            !Self.imageExtensions.contains($0.pathExtension.lowercased())
        } ?? false
        playbackTap.setRunning(viewerMode == .playback && videoLoaded)
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

    /// Направление шторки сравнения.
    enum WipeOrientation: String, CaseIterable {
        case vertical    // вертикальная линия, тянется по горизонтали
        case horizontal  // горизонтальная линия, тянется по вертикали
        case diagonal    // 45°
    }

    @Published var compareMode: CompareMode = .off
    @Published var wipeOrientation: WipeOrientation = .vertical
    /// Позиция шторки (0…1; слева/сверху — плейбек).
    @Published var wipePosition: Double = 0.5
    /// Непрозрачность плейбека в режиме blend.
    @Published var blendOpacity: Double = 0.5
    /// Позиция панели дублей (left/right) — реактивно для всех окон.
    @Published var panelSide: String =
        UserDefaults.standard.string(forKey: "panelSide") ?? "right" {
        didSet { UserDefaults.standard.set(panelSide, forKey: "panelSide") }
    }
    /// Хоткей-менеджер (для окружения фулскрин-окон).
    weak var hotkeysRef: HotkeyManager?
    /// Фактическая высота зоны кнопок окна (тайтлбар скрыт, кнопки поверх контента).
    @Published var windowTopInset: CGFloat = 26

    // MARK: - LUT

    struct LUTInfo: Identifiable, Equatable {
        var id: String { fileName }
        var fileName: String
        var name: String
    }

    /// Импортированные LUT-файлы (папка Application Support/TakeShot/LUTs).
    @Published var availableLUTs: [LUTInfo] = []
    private var currentCube: CubeLUT?
    /// В текущем плейбек-файле лук уже запечён (метка com.takeshot.lut).
    @Published var playbackFileHasBakedLUT = false
    /// Ручное отключение LUT для текущего клипа (лук пришёл с камеры и т.п.).
    @Published var playbackLUTSuppressed = false {
        didSet { applyPlaybackLUT() }
    }

    nonisolated static var lutsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        return base.appendingPathComponent("TakeShot/LUTs", isDirectory: true)
    }

    func reloadLUTList() {
        let dir = Self.lutsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        availableLUTs = files
            .filter { $0.pathExtension.lowercased() == "cube" }
            .map { LUTInfo(fileName: $0.lastPathComponent,
                           name: $0.deletingPathExtension().lastPathComponent) }
            .sorted { $0.name < $1.name }
    }

    /// Импорт .cube: копируется в папку приложения и сразу выбирается.
    func importLUT() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "cube")!]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let dir = Self.lutsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var lastName: String?
        for url in panel.urls {
            let dest = dir.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            do {
                try FileManager.default.copyItem(at: url, to: dest)
                lastName = url.lastPathComponent
            } catch {
                lastError = "LUT import failed: \(error.localizedDescription)"
            }
        }
        reloadLUTList()
        if let lastName {
            selectLUT(fileName: lastName)
        }
    }

    func selectLUT(fileName: String?) {
        settings.lutFileName = fileName
        if fileName != nil, settings.lutPreviewEnabled != true,
           settings.lutRecordEnabled != true {
            settings.lutPreviewEnabled = true // выбрали LUT — очевидно хотят видеть
        }
        rebuildLUT()
    }

    var lutPreviewOn: Bool {
        get { settings.lutPreviewEnabled ?? false }
        set {
            settings.lutPreviewEnabled = newValue
            rebuildLUT()
        }
    }

    var lutRecordOn: Bool {
        get { settings.lutRecordEnabled ?? false }
        set {
            settings.lutRecordEnabled = newValue
            rebuildLUT()
        }
    }

    /// Интенсивность LUT (0…1); по умолчанию 1.
    var lutIntensity: Double {
        get { settings.lutIntensity ?? 1 }
        set {
            settings.lutIntensity = newValue
            rebuildLUT()
        }
    }

    /// Пересобрать фильтр, раздать конвейеру и плейбеку.
    func rebuildLUT() {
        currentCube = nil
        if let fileName = settings.lutFileName {
            let url = Self.lutsDirectory.appendingPathComponent(fileName)
            do {
                currentCube = try CubeLUT.load(url: url)
            } catch {
                lastError = "LUT: \(error.localizedDescription)"
                settings.lutFileName = nil
            }
        }
        pipeline.setLUT(currentCube,
                        preview: settings.lutPreviewEnabled ?? false,
                        record: settings.lutRecordEnabled ?? false,
                        intensity: settings.lutIntensity ?? 1)
        applyPlaybackLUT()
    }

    /// LUT на плейбек — тем же фильтром через videoComposition, но с учётом
    /// уже запечённого лука: наш файл с меткой com.takeshot.lut или ручное
    /// отключение на клип — и LUT повторно не накладывается.
    func applyPlaybackLUT() {
        guard let item = player.currentItem else { return }
        guard settings.lutPreviewEnabled ?? false, !playbackFileHasBakedLUT,
              !playbackLUTSuppressed,
              let cube = currentCube, let filter = cube.makeFilter() else {
            item.videoComposition = nil
            return
        }
        let intensity = settings.lutIntensity ?? 1
        item.videoComposition = AVMutableVideoComposition(
            asset: item.asset) { request in
            let source = request.sourceImage
            filter.setValue(source, forKey: kCIInputImageKey)
            let filtered = filter.outputImage ?? source
            let mixed = CapturePipeline.mix(source: source, filtered: filtered,
                                            intensity: intensity)
            request.finish(with: mixed, context: nil)
        }
    }

    /// Проверить метку запечённого LUT у загруженного клипа (асинхронно).
    private func detectBakedLUT(for item: AVPlayerItem) {
        playbackFileHasBakedLUT = false
        Task { [weak self] in
            let metadata = (try? await item.asset.load(.metadata)) ?? []
            let baked = metadata.contains { ($0.key as? String) == TakeWriter.lutKey }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.playbackFileHasBakedLUT = baked
                self.applyPlaybackLUT()
            }
        }
    }
    /// Крупная панель аудиоканалов поверх плеера.
    @Published var showAudioPanel = false
    /// Громкость плейбека (только просмотр, на запись не влияет).
    @Published var playbackVolume: Double = 1.0 {
        didSet { player.volume = Float(playbackVolume) }
    }
    /// Отдельное фулскрин-окно плейбека (не системный фулскрин приложения).
    @Published var isPlaybackFullscreen = false
    private var playbackFullscreenWindow: NSWindow?
    /// Фулскрин-окно живого сигнала (плеер на весь экран в режиме река).
    @Published var isLiveFullscreen = false
    private var liveFullscreenWindow: NSWindow?

    /// Плеер для просмотра дублей.
    let player = AVPlayer()
    /// Единый рендер плейбека (кадры из плеера → sample-buffer слои).
    let playbackTap = PlaybackFrameTap()

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
            PlaybackFullscreenView()
                .environmentObject(self)
                .environmentObject(hotkeysRef ?? HotkeyManager())
                .tint(accentColor))
        window.setFrame(screen.frame, display: true)
        window.makeKeyAndOrderFront(nil)
        playbackFullscreenWindow = window
        isPlaybackFullscreen = true
    }

    /// Фулскрин ТОЛЬКО плеера в режиме река (зеркало лайва в безрамочном окне).
    func toggleLiveFullscreen() {
        if isLiveFullscreen {
            liveFullscreenWindow?.orderOut(nil)
            liveFullscreenWindow = nil
            pipeline.fullscreenMirrorEnabled = false
            isLiveFullscreen = false
            return
        }
        guard let screen = NSApp.mainWindow?.screen ?? NSScreen.main else { return }
        pipeline.fullscreenMirrorEnabled = true
        let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false, screen: screen)
        window.level = .statusBar
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView:
            LiveFullscreenView()
                .environmentObject(self)
                .environmentObject(hotkeysRef ?? HotkeyManager())
                .tint(accentColor))
        window.setFrame(screen.frame, display: true)
        window.makeKeyAndOrderFront(nil)
        liveFullscreenWindow = window
        isLiveFullscreen = true
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
            let item = AVPlayerItem(url: url)
            player.replaceCurrentItem(with: item)
            playbackTap.attach(to: item)
            playbackLUTSuppressed = false
            detectBakedLUT(for: item) // применит LUT сам, когда узнает про метку
            player.play()
        }
        viewerMode = .playback
        updateTapRunning()
    }
    @Published var settings = CaptureSettings.loaded() {
        didSet {
            settings.save()
            pushConfig()
            L10n.apply(appLanguage)
            if oldValue.destinationPath != settings.destinationPath {
                resetLibraryForNewDestination()
            }
            // cam/postfix/шаблон/паддинг влияют на имя — пересчитываем предупреждение
            if oldValue.cameraLabel != settings.cameraLabel
                || oldValue.postfix != settings.postfix
                || oldValue.namingTemplate != settings.namingTemplate
                || oldValue.clipPadWidth != settings.clipPadWidth {
                refreshNameCollision()
            }
        }
    }

    /// Пересчитать предупреждение о занятом имени для СЛЕДУЮЩЕГО дубля.
    /// Во время записи не показываем: пишущийся файл, естественно, существует.
    func refreshNameCollision() {
        guard !isRecording else { nameCollision = nil; return }
        let engine = NamingEngine(template: settings.namingTemplate)
        let context = NamingContext(
            project: settings.projectName, date: Date(),
            take: nextTakeNumber, reel: roll, camera: settings.cameraLabel,
            postfix: settings.postfix ?? "",
            clipPadding: settings.clipPadWidthEffective,
            timecode: currentTimecode)
        let url = destinationRoot
            .appendingPathComponent(engine.relativeDirectory(for: context))
            .appendingPathComponent(engine.fileName(for: context))
            .appendingPathExtension("mov")
        nameCollision = FileManager.default.fileExists(atPath: url.path)
            ? url.lastPathComponent : nil
    }

    /// Новая папка записи: старые дубли/файлы к ней не относятся — чистим и сканируем заново.
    private func resetLibraryForNewDestination() {
        takes.removeAll()
        otherFiles.removeAll()
        thumbnails.removeAll()
        otherThumbnails.removeAll()
        otherDurations.removeAll()
        scannedPaths.removeAll()
        nextTakeNumber = 1
        scanDestinationFolder()
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
        refreshNameCollision()
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
            self?.refreshNameCollision() // старт скрывает, стоп — пересчитывает
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

    /// Акцентный цвет контролов; по умолчанию нейтральный серый, не эппл-синий.
    var accentColor: Color {
        get { settings.accentHex.flatMap(Color.init(hex:)) ?? Color(hex: "#9A9A9E")! }
        set { settings.accentHex = newValue.hexString }
    }

    /// Сбросить только цвета интерфейса к дефолтам.
    func resetColors() {
        settings.playerBackgroundHex = nil
        settings.appBackgroundHex = nil
        settings.accentHex = nil
    }

    /// Сбросить ВСЕ настройки приложения к заводским (папку записи сохраняем,
    /// чтобы не потерять текущую библиотеку). Хоткеи и раскладку панели тоже.
    func resetAllSettings() {
        let keepDestination = settings.destinationPath
        var fresh = CaptureSettings()
        fresh.destinationPath = keepDestination
        settings = fresh
        panelSide = "right"
        UserDefaults.standard.removeObject(forKey: "TakeShot.Hotkeys")
        L10n.apply(appLanguage)
        rebuildLUT()
    }

    /// Цвет фона окна; по умолчанию ~полторы ступени ниже миддл-грея.
    var appBackground: Color {
        get {
            settings.appBackgroundHex.flatMap(Color.init(hex:))
                ?? Color(hex: "#464646")!
        }
        set { settings.appBackgroundHex = newValue.hexString }
    }

    /// Номер клипа с текущим паддингом (для поля и превью имени).
    var clipDisplay: String {
        String(format: "%0\(settings.clipPadWidthEffective)d", nextTakeNumber)
    }

    /// Применить введённый в поле текст клипа: цифры → номер,
    /// количество набранных цифр (с ведущими нулями) → паддинг имени.
    func commitClipText(_ text: String) {
        let digits = text.filter(\.isNumber)
        guard !digits.isEmpty else { return }
        settings.clipPadWidth = min(4, max(2, digits.count))
        nextTakeNumber = min(9999, max(0, Int(digits) ?? nextTakeNumber))
    }

    /// Применить пресет именования: шаблон, ширина клипа и ширина ролла.
    func applyNamingPreset(
        _ preset: (key: String, template: String, clipDigits: Int, rollDigits: Int?)) {
        settings.namingTemplate = preset.template
        settings.clipPadWidth = preset.clipDigits
        if let rollDigits = preset.rollDigits,
           let range = roll.range(of: "[0-9]+$", options: .regularExpression),
           let number = Int(roll[range]) {
            roll = roll[..<range.lowerBound] + String(format: "%0\(rollDigits)d", number)
        }
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
        // дождаться дозаписи файлов в фоне (не блокируя UI)
        Task { await pipeline.finishPendingWrites() }
    }

    /// Блокирующий флаш при выходе из приложения — чтобы файл не усёкся.
    func flushOnTerminate() {
        let sem = DispatchSemaphore(value: 0)
        Task {
            await pipeline.finishPendingWrites()
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 5)
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
            let startTC = await TimecodeReader.startTimecode(of: asset)
            let take = Take(
                url: url,
                displayName: url.deletingPathExtension().lastPathComponent,
                scene: "",
                roll: value(TakeWriter.rollKey) ?? "",
                takeNumber: Int(value(TakeWriter.clipKey) ?? "") ?? 0,
                startTimecode: startTC,
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
        // файл мог появиться в папке извне — обновим предупреждение о занятом имени
        refreshNameCollision()
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
                    let asset = AVURLAsset(url: url)
                    let generator = AVAssetImageGenerator(asset: asset)
                    generator.appliesPreferredTrackTransform = true
                    generator.maximumSize = CGSize(width: 480, height: 480)
                    if let (cgImage, _) = try? await generator.image(
                        at: CMTime(seconds: 0.5, preferredTimescale: 600)) {
                        image = NSImage(cgImage: cgImage,
                                        size: NSSize(width: cgImage.width,
                                                     height: cgImage.height))
                    }
                    if let duration = try? await asset.load(.duration) {
                        let seconds = duration.seconds
                        await MainActor.run { [weak self] in
                            self?.otherDurations[url] = seconds
                        }
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
