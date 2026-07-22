import AppKit
import AVFoundation
import CaptureCore
import Combine
import CoreMedia
import CoreVideo
import Foundation
import SwiftUI

/// App UI state. The heavy frame work lives in CapturePipeline; the controller
/// just pushes configuration in and events back out.
@MainActor
final class CaptureController: ObservableObject {
    @Published var devices: [CaptureDeviceInfo] = []
    /// Capture starts automatically when a device is selected — there's no separate button.
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
    /// Take preview frames for thumbnail mode.
    @Published var thumbnails: [Take.ID: NSImage] = [:]
    /// VANC packet stats for the monitor window.
    @Published var vancStats: [VancPacketStat] = []
    /// Roll (reel/media). Changing the roll resets the clip number.
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
    /// The filename the current naming combo would produce already exists in the folder.
    /// nil — no collision. We warn the operator BEFORE recording (the stepper landed on
    /// a taken number, the roll was rolled back, etc.); we won't overwrite anyway.
    @Published var nameCollision: String?
    /// Video and photos in the record folder that didn't come from TakeShot (dropped in by hand).
    @Published var otherFiles: [URL] = []
    /// Thumbnails for Other content.
    @Published var otherThumbnails: [URL: NSImage] = [:]
    /// Video durations in Other content (seconds).
    @Published var otherDurations: [URL: Double] = [:]
    /// Error toast: pops up over the footer and dismisses itself after a few seconds.
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
    /// Per-channel audio peak levels, dBFS (for the meters).
    @Published var audioLevels: [Float] = []
    /// View mode: live signal or playback of a recording.
    @Published var viewerMode: ViewerMode = .record {
        didSet {
            if viewerMode == .record {
                player.pause()
            }
            updateTapRunning()
            updateScopesRunning()
        }
    }

    /// Polling playback frames is only needed when the view is actually visible.
    private func updateTapRunning() {
        let videoLoaded = playbackURL.map {
            !Self.imageExtensions.contains($0.pathExtension.lowercased())
        } ?? false
        playbackTap.setRunning(viewerMode == .playback && videoLoaded)
    }
    /// What's currently loaded in the player (for highlighting in the list).
    @Published var playbackURL: URL?

    enum ViewerMode: String, CaseIterable {
        case record
        case playback
    }

    /// Live vs. playback compare mode.
    enum CompareMode: String, CaseIterable, Identifiable {
        case off        // playback only
        case wipe       // wipe
        case blend      // overlay with transparency
        case sideBySide // side by side
        var id: String { rawValue }
    }

    /// Compare wipe direction.
    enum WipeOrientation: String, CaseIterable {
        case vertical    // vertical line, drags horizontally
        case horizontal  // horizontal line, drags vertically
        case diagonal    // 45°
    }

    @Published var compareMode: CompareMode = .off
    @Published var wipeOrientation: WipeOrientation = .vertical
    /// Wipe position (0…1; left/top is playback).
    @Published var wipePosition: Double = 0.5
    /// Playback opacity in blend mode.
    @Published var blendOpacity: Double = 0.5
    /// Takes-panel position (left/right) — reactive for all windows.
    @Published var panelSide: String =
        UserDefaults.standard.string(forKey: "panelSide") ?? "right" {
        didSet { UserDefaults.standard.set(panelSide, forKey: "panelSide") }
    }
    /// Hotkey manager (for the fullscreen windows' environment).
    weak var hotkeysRef: HotkeyManager?
    /// Actual height of the window-button area (title bar hidden, buttons over content).
    @Published var windowTopInset: CGFloat = 26

    // MARK: - LUT

    struct LUTInfo: Identifiable, Equatable {
        var id: String { fileName }
        var fileName: String
        var name: String
    }

    /// Imported LUT files (the Application Support/TakeShot/LUTs folder).
    @Published var availableLUTs: [LUTInfo] = []
    private var currentCube: CubeLUT?
    /// The current playback file already has the look baked in (com.takeshot.lut tag).
    @Published var playbackFileHasBakedLUT = false
    /// Manual LUT off for the current clip (the look came from the camera, etc.).
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

    /// Import .cube: copied into the app folder and selected right away.
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

    /// Open the imported-LUTs folder in Finder.
    func openLUTsInFinder() {
        let dir = Self.lutsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    /// Delete all imported .cube files and clear the selected LUT.
    func clearLUTs() {
        let dir = Self.lutsDirectory
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension.lowercased() == "cube" {
            try? FileManager.default.removeItem(at: file)
        }
        selectLUT(fileName: nil)
        reloadLUTList()
    }

    func selectLUT(fileName: String?) {
        settings.lutFileName = fileName
        if fileName != nil, settings.lutPreviewEnabled != true,
           settings.lutRecordEnabled != true {
            settings.lutPreviewEnabled = true // picked a LUT — clearly want to see it
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

    /// LUT intensity (0…1); default 1. On each slider tick we do NOT re-read the
    /// .cube from disk (that hung the slider) — we only change the mix coefficient
    /// in the pipeline, and touch playback only in playback mode.
    var lutIntensity: Double {
        get { settings.lutIntensity ?? 1 }
        set {
            let clamped = min(1, max(0, newValue))
            settings.lutIntensity = clamped
            pipeline.setLUTIntensity(clamped)
            if viewerMode == .playback { applyPlaybackLUT() }
        }
    }

    /// Rebuild the filter and hand it to the pipeline and playback.
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
        pipeline.setVideoLevels(settings.videoLevels)
        applyPlaybackLUT()
    }

    /// LUT on playback — the same filter via videoComposition, but accounting for
    /// an already-baked look: our file tagged com.takeshot.lut or a manual
    /// per-clip off — and the LUT isn't applied twice.
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

    /// Check the loaded clip's baked-LUT tag (asynchronously).
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
    /// Large audio-channel panel over the player.
    @Published var showAudioPanel = false
    /// Scopes panel (waveform + histogram) over the player.
    @Published var showScopes = false {
        didSet { updateScopesRunning() }
    }
    /// Latest scope data (from live or playback, whichever is visible).
    @Published var scopeData: ScopeData?

    /// Route scope analysis to whichever source is actually on screen.
    private func updateScopesRunning() {
        pipeline.setScopesEnabled(showScopes && viewerMode == .record)
        playbackTap.setScopesEnabled(showScopes && viewerMode == .playback)
        if !showScopes { scopeData = nil }
    }
    /// Playback volume (viewing only, doesn't affect recording).
    @Published var playbackVolume: Double = 1.0 {
        didSet { player.volume = Float(playbackVolume) }
    }
    /// A separate playback fullscreen window (not the system app fullscreen).
    @Published var isPlaybackFullscreen = false
    private var playbackFullscreenWindow: NSWindow?
    /// Live-signal fullscreen window (player fills the screen in record mode).
    @Published var isLiveFullscreen = false
    private var liveFullscreenWindow: NSWindow?

    /// Player for reviewing takes.
    let player = AVPlayer()
    /// Unified playback render (frames from the player → sample-buffer layers).
    let playbackTap = PlaybackFrameTap()

    // MARK: - external monitor output

    /// The selected external display (by displayID); nil — off.
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

    /// Displays other than the one the app's main window is on.
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

    /// Shared factory for the borderless full-screen output windows
    /// (playback fullscreen, live fullscreen, external monitor).
    private func makeBorderlessWindow(
        on screen: NSScreen, content: some View,
        behavior: NSWindow.CollectionBehavior = [.fullScreenAuxiliary],
        makeKey: Bool = true) -> NSWindow {
        let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false, screen: screen)
        window.level = .statusBar
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.collectionBehavior = behavior
        window.contentView = NSHostingView(rootView: content)
        window.setFrame(screen.frame, display: true)
        if makeKey {
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFront(nil)
        }
        return window
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
        externalWindow = makeBorderlessWindow(
            on: screen,
            content: ExternalOutputView().environmentObject(self),
            behavior: [.fullScreenAuxiliary, .stationary],
            makeKey: false)
    }

    /// System fullscreen of the main window (immersive mode).
    func toggleFullscreen() {
        NSApp.mainWindow?.toggleFullScreen(nil)
    }

    /// Fullscreen for PLAYBACK ONLY: a borderless full-screen window;
    /// the app itself stays as it was (this isn't the green button).
    func togglePlaybackFullscreen() {
        if isPlaybackFullscreen {
            playbackFullscreenWindow?.orderOut(nil)
            playbackFullscreenWindow = nil
            isPlaybackFullscreen = false
            return
        }
        guard let screen = NSApp.mainWindow?.screen ?? NSScreen.main else { return }
        playbackFullscreenWindow = makeBorderlessWindow(
            on: screen,
            content: PlaybackFullscreenView()
                .environmentObject(self)
                .environmentObject(hotkeysRef ?? HotkeyManager())
                .tint(accentColor))
        isPlaybackFullscreen = true
    }

    /// Fullscreen for the PLAYER ONLY in record mode (a live mirror in a borderless window).
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
        liveFullscreenWindow = makeBorderlessWindow(
            on: screen,
            content: LiveFullscreenView()
                .environmentObject(self)
                .environmentObject(hotkeysRef ?? HotkeyManager())
                .tint(accentColor))
        isLiveFullscreen = true
    }

    // MARK: - audio channels (record mask)

    /// Whether the channel is included in the recording.
    func isChannelEnabled(_ index: Int) -> Bool {
        guard let mask = settings.audioChannelMask else { return true }
        return mask & (1 << index) != 0
    }

    func toggleAudioChannel(_ index: Int) {
        var mask = settings.audioChannelMask ?? 0xFFFF
        mask ^= (1 << index)
        // all enabled — store nil (= "all", including if more channels appear later)
        settings.audioChannelMask = (mask & 0xFFFF) == 0xFFFF ? nil : mask
    }

    /// Playback audio output.
    var playbackOutputUID: String? {
        get { settings.playbackAudioDeviceUID }
        set {
            settings.playbackAudioDeviceUID = newValue
            player.audioOutputDeviceUniqueID = newValue
        }
    }

    /// Open a file in the player and switch to playback mode.
    /// Photos are just displayed (AVPlayer isn't needed for them).
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
            detectBakedLUT(for: item) // applies the LUT itself once it learns the tag
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
            // cam/postfix/template/padding affect the name — recompute the warning
            if oldValue.cameraLabel != settings.cameraLabel
                || oldValue.postfix != settings.postfix
                || oldValue.namingTemplate != settings.namingTemplate
                || oldValue.clipPadWidth != settings.clipPadWidth {
                refreshNameCollision()
            }
        }
    }

    /// Recompute the taken-name warning for the NEXT take.
    /// Not shown while recording: the file being written naturally exists.
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
            .appendingPathComponent(engine.fileName(for: context))
            .appendingPathExtension("mov")
        nameCollision = FileManager.default.fileExists(atPath: url.path)
            ? url.lastPathComponent : nil
    }

    /// New record folder: old takes/files don't apply — clear and rescan.
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

    /// UI language; English by default.
    var appLanguage: AppLanguage {
        get { settings.appLanguage.flatMap(AppLanguage.init(rawValue:)) ?? .english }
        set { settings.appLanguage = newValue.rawValue }
    }

    let pipeline: CapturePipeline

    private let backend: AggregateBackend

    var backendAvailable: Bool { backend.isAvailable }

    /// Whether the demo source is selected (to show the "REC demo camera" button).
    var isMockSelected: Bool {
        selectedDeviceID?.hasPrefix("mock:") ?? false
    }

    init(extraBackends: [(String, CaptureBackend)] = []) {
        // the demo source is always last; when a real board appears the app
        // switches to it automatically (see refreshDevices)
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
        refreshDevices() // selecting the first device starts capture via didSet
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
            guard let self else { return }
            self.isRecording = recording
            self.refreshNameCollision() // start hides it, stop recomputes
            // multicam: the other cameras in sync with the main one
            for channel in self.extraChannels { channel.setRecording(recording) }
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
        pipeline.onScopeData = { [weak self] data in
            self?.scopeData = data
        }
        playbackTap.onScopeData = { [weak self] data in
            self?.scopeData = data
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

    /// UI theme from settings.
    var colorScheme: ColorScheme? {
        switch settings.appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    /// Player backdrop color; black by default.
    var playerBackground: Color {
        get {
            settings.playerBackgroundHex.flatMap(Color.init(hex:))
                ?? Color(hex: "#000000")!
        }
        set { settings.playerBackgroundHex = newValue.hexString }
    }

    /// Control accent color; white by default.
    var accentColor: Color {
        get { settings.accentHex.flatMap(Color.init(hex:)) ?? Color(hex: "#FFFFFF")! }
        set { settings.accentHex = newValue.hexString }
    }

    /// Reset only the UI colors to defaults.
    func resetColors() {
        settings.playerBackgroundHex = nil
        settings.appBackgroundHex = nil
        settings.accentHex = nil
    }

    /// Reset ALL app settings to factory (keep the record folder so we don't lose
    /// the current library). Hotkeys and panel layout too.
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

    /// Window background color; grey by default — 15% brightness of black (~#262626).
    var appBackground: Color {
        get {
            settings.appBackgroundHex.flatMap(Color.init(hex:))
                ?? Color(hex: "#262626")!
        }
        set { settings.appBackgroundHex = newValue.hexString }
    }

    /// Clip number with the current padding (for the field and name preview).
    var clipDisplay: String {
        String(format: "%0\(settings.clipPadWidthEffective)d", nextTakeNumber)
    }

    /// Apply the clip text typed into the field: digits → number,
    /// the count of typed digits (with leading zeros) → filename padding.
    func commitClipText(_ text: String) {
        let digits = text.filter(\.isNumber)
        guard !digits.isEmpty else { return }
        settings.clipPadWidth = min(4, max(2, digits.count))
        nextTakeNumber = min(9999, max(0, Int(digits) ?? nextTakeNumber))
    }

    /// Apply a naming preset: template, clip width, and roll width.
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

    // MARK: - naming-field steppers

    func stepRoll(_ delta: Int) {
        roll = FieldStepper.stepTrailingNumber(roll, by: delta)
    }

    func stepCamera(_ delta: Int) {
        settings.cameraLabel = FieldStepper.stepLetter(settings.cameraLabel, by: delta)
    }

    /// Hotkey: set/clear the last take's rating.
    func toggleLastRating(_ rating: TakeRating) {
        guard let last = takes.last else { return }
        setRating(last.rating == rating ? .none : rating, for: last)
    }

    private func pushConfig() {
        pipeline.update(config: .init(
            settings: settings, roll: roll, takeNumber: nextTakeNumber))
        for channel in extraChannels {
            channel.update(settings: settings, roll: roll, takeNumber: nextTakeNumber)
        }
    }

    // MARK: - multicam

    /// Extra cameras (the first/main one lives in this controller).
    @Published var extraChannels: [CameraChannel] = []
    /// Multicam on (demo adds a second camera; on hardware — the other boards).
    @Published var multicamOn = false

    /// All cameras for the preview grid: main (nil channel) + extras.
    var allCameraLabels: [String] {
        [settings.cameraLabel] + extraChannels.map(\.camLabel)
    }

    func toggleMulticam() {
        setMulticam(!multicamOn)
    }

    func setMulticam(_ on: Bool) {
        for channel in extraChannels { channel.stop() }
        extraChannels.removeAll()
        multicamOn = on
        guard on else { return }

        let nextLetter = FieldStepper.stepLetter(settings.cameraLabel, by: 1)
        if isMockSelected {
            // demo: a second mock camera
            let mock = MockCaptureBackend()
            let channel = CameraChannel(
                camLabel: nextLetter, backend: mock,
                deviceID: MockCaptureBackend.deviceID, settings: settings, roll: roll)
            channel.onTakeFinished = { [weak self] take in self?.appendChannelTake(take) }
            channel.start()
            extraChannels = [channel]
        } else {
            // hardware: each OTHER DeckLink board is its own channel
            let others = devices.filter {
                $0.id.hasPrefix("decklink:") && $0.id != selectedDeviceID
            }
            var channels: [CameraChannel] = []
            var letter = nextLetter
            for device in others {
                let rawID = String(device.id.dropFirst("decklink:".count))
                let channel = CameraChannel(
                    camLabel: letter, backend: DeckLinkBackendAdapter(),
                    deviceID: rawID, settings: settings, roll: roll)
                channel.onTakeFinished = { [weak self] take in self?.appendChannelTake(take) }
                channel.start()
                channels.append(channel)
                letter = FieldStepper.stepLetter(letter, by: 1)
            }
            extraChannels = channels
        }
    }

    private func appendChannelTake(_ take: Take) {
        takes.append(take)
        takes.sort { $0.recordedAt < $1.recordedAt }
        exportTakeLog()
        generateThumbnail(for: take)
    }

    // MARK: - capture control

    func refreshDevices() {
        devices = backend.devices()

        let realDevices = devices.filter { !$0.id.hasPrefix("mock:") }
        if let selected = selectedDeviceID, !devices.contains(where: { $0.id == selected }) {
            // the selected device was unplugged — fall back to the first available
            lastError = L("device_disconnected")
            selectedDeviceID = devices.first?.id
        } else if selectedDeviceID == nil || (isMockSelected && !realDevices.isEmpty) {
            // nothing selected, or the demo source is selected but a real board
            // appeared — switch to it (capture starts itself via didSet)
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
        // await finishing the files in the background (without blocking the UI)
        Task { await pipeline.finishPendingWrites() }
    }

    /// A blocking flush on app exit — so the file isn't truncated.
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

    /// Click the circle: none → good → bad → none.
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

    /// Set a free-text comment on a take (persisted to the CSV Comments column).
    func setComment(_ comment: String, for take: Take) {
        guard let idx = takes.firstIndex(of: take) else { return }
        guard takes[idx].comment != comment else { return }
        takes[idx].comment = comment
        exportTakeLog()
    }

    // MARK: - frame grab

    /// Grab the current frame as a PNG next to the takes. In playback it grabs the
    /// current player frame (with the LUT); otherwise the live processed frame.
    func grabFrame() {
        if viewerMode == .playback, let item = player.currentItem,
           let url = playbackURL,
           !Self.imageExtensions.contains(url.pathExtension.lowercased()) {
            grabPlaybackFrame(item: item)
        } else {
            pipeline.grabNextFrame { [weak self] png in self?.saveGrab(png) }
        }
    }

    private func grabPlaybackFrame(item: AVPlayerItem) {
        let generator = AVAssetImageGenerator(asset: item.asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.appliesPreferredTrackTransform = true
        if let composition = item.videoComposition {
            generator.videoComposition = composition
        }
        let time = player.currentTime()
        Task { [weak self] in
            let cg = try? await generator.image(at: time).image
            await MainActor.run {
                guard let cg else { self?.lastError = "Frame grab failed"; return }
                self?.saveGrab(NSBitmapImageRep(cgImage: cg)
                    .representation(using: .png, properties: [:]))
            }
        }
    }

    private func saveGrab(_ png: Data?) {
        guard let png else { lastError = "Frame grab failed"; return }
        let base = settings.projectName.isEmpty ? settings.cameraLabel : settings.projectName
        let stamp = currentTimecode?.fileNameSafe ?? Self.grabTimeStamp()
        let name = NamingEngine.sanitize("\(base)_grab_\(stamp)")
        let url = CapturePipeline.uniqueURL(for: destinationRoot
            .appendingPathComponent(name).appendingPathExtension("png"))
        do {
            try FileManager.default.createDirectory(
                at: destinationRoot, withIntermediateDirectories: true)
            try png.write(to: url)
            scanDestinationFolder() // show it in Other content right away
        } catch {
            lastError = "Frame grab failed: \(error.localizedDescription)"
        }
    }

    private static func grabTimeStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }

    /// The metadata log URL (for "show in Finder").
    var takeLogURL: URL {
        destinationRoot.appendingPathComponent(TakeLogExporter.fileName)
    }

    /// The record root folder (for the "open folder" button).
    var destinationRoot: URL {
        URL(fileURLWithPath: (settings.destinationPath as NSString).expandingTildeInPath)
    }

    func openDestinationInFinder() {
        try? FileManager.default.createDirectory(at: destinationRoot,
                                                 withIntermediateDirectories: true)
        NSWorkspace.shared.open(destinationRoot)
    }

    /// Change-record-folder dialog (used from both Settings and the bottom bar).
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

    // MARK: - folder sync (Other content)

    nonisolated private static let videoExtensions: Set<String> = ["mov", "mp4", "mxf", "m4v", "avi"]
    nonisolated private static let imageExtensions: Set<String> =
        ["jpg", "jpeg", "png", "heic", "tif", "tiff", "dng", "arw", "cr2", "webp"]

    /// Light polling of the record folder: video files not among our takes
    /// are shown in a separate Other content block.
    private func startFolderSync() {
        Task { [weak self] in
            while let self, !Task.isCancelled {
                self.scanDestinationFolder()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// Paths already checked for the TakeShot tag (so we don't re-read metadata).
    private var scannedPaths: Set<String> = []

    private func scanDestinationFolder() {
        let root = destinationRoot
        let ownTakePaths = Set(takes.map { $0.url.path })
        Task.detached(priority: .utility) { [weak self] in
            let candidates = Self.findForeignVideos(root: root, excluding: ownTakePaths)
            await self?.classifyFoundFiles(candidates)
        }
    }

    /// Our files (the com.takeshot.origin QuickTime tag) return to the takes list
    /// after a restart; the rest are Other content.
    private func classifyFoundFiles(_ candidates: [URL]) async {
        var restored: [Take] = []
        var foreign: [URL] = []
        let meta = (try? String(contentsOf: takeLogURL, encoding: .utf8))
            .map(TakeLogExporter.parseMetadata(csv:)) ?? [:]

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
                rating: meta[url.lastPathComponent]?.rating ?? .none,
                comment: meta[url.lastPathComponent]?.comment ?? "",
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
        // a file may have appeared in the folder externally — refresh the taken-name warning
        refreshNameCollision()
    }

    /// The next clip number — after the max in the current roll.
    private func continueClipNumbering() {
        let maxClip = takes.filter { $0.roll == roll }.map(\.takeNumber).max() ?? 0
        nextTakeNumber = maxClip + 1
    }

    /// Thumbnails for Other content: photos directly, videos via a frame generator.
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
        let cutoff = Date().addingTimeInterval(-3) // don't touch files still being written
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

    /// Resolve-compatible CSV: rewritten on every take and every circle-take mark
    /// — in Resolve it's imported via Media Pool → Import Metadata.
    private func exportTakeLog() {
        let takes = takes
        let root = destinationRoot
        Task.detached(priority: .utility) {
            try? TakeLogExporter.write(takes: takes, toDirectory: root)
        }
    }

    /// A preview frame from the recorded file; the file finalizes asynchronously,
    /// so several attempts with a pause.
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

// MARK: - CaptureBackendDelegate (callbacks from capture threads — straight into the pipeline)

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
