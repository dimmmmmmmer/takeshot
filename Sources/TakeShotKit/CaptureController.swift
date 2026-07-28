import AppKit
import AVFoundation
import CBraw
import CaptureCore
import CryptoKit
import Combine
import CoreMedia
import CoreVideo
import Foundation
import os.log
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
    /// Per-frame values (TC/meters/scopes) — deliberately NOT @Published here;
    /// views that show them observe `live` so the rest of the UI stays still.
    let live = LiveSignal()
    var currentTimecode: Timecode? { live.currentTimecode }
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
    /// Sticky alarm: recording-integrity problems (writer failure, disk low,
    /// lost takes) must NOT vanish after five seconds like a toast. Cleared
    /// by the operator or by the next successful take start.
    @Published var persistentAlert: String?

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
    /// Neutral info toast (grab saved etc.) — green, self-dismissing.
    @Published var lastNotice: String? {
        didSet {
            noticeDismissTask?.cancel()
            guard lastNotice != nil else { return }
            noticeDismissTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                self?.lastNotice = nil
            }
        }
    }
    private var noticeDismissTask: Task<Void, Never>?
    /// Per-channel audio peak levels, dBFS (for the meters; see `live`).
    var audioLevels: [Float] { live.audioLevels }
    /// View mode: live signal or playback of a recording.
    @Published var viewerMode: ViewerMode = .record {
        didSet {
            if viewerMode == .record {
                player.pause()
                rawPlayer?.pause() // a looping BRAW decode must not fight capture
            }
            updateAudioMonitorRouting()
            updateTapRunning()
            updateScopesRunning()
            wirePlayoutRouting()
        }
    }

    /// Polling playback frames is only needed when the view is actually visible.
    func updateTapRunning() {
        // stills tick through the tap too (compare keeps the live half moving)
        let loaded = playbackURL != nil && rawPlayer == nil
        playbackTap.setRunning(viewerMode == .playback && loaded)
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

    @Published var compareMode: CompareMode = .off {
        didSet { pushCompare() }
    }
    @Published var wipeOrientation: WipeOrientation = .vertical {
        didSet { pushCompare() }
    }
    /// Wipe position (0…1; left/top is playback).
    @Published var wipePosition: Double = 0.5 {
        didSet { pushCompare() }
    }
    /// Playback opacity in blend mode.
    @Published var blendOpacity: Double = 0.5 {
        didSet { pushCompare() }
    }

    /// Verified offload of an ARBITRARY folder (camera cards, sound, etc.):
    /// recursive copy with SHA-256 on both sides and a CSV manifest.
    /// TakeShot's own takes don't need this — they aren't the originals.
    @Published var offloadStatus: String?
    nonisolated static let backupQueue = DispatchQueue(
        label: "takeshot.offload", qos: .utility)

    /// Hardware playout: mirrors the viewer to the DeckLink output chosen in
    /// settings. Rebuilt on device/format changes; routed by viewer mode.
    var playoutFeeder: PlayoutFeeder?

    /// B-side clip for take-vs-take compare (nil — compare against live).
    @Published var compareClipURL: URL? {
        didSet {
            playbackTap.setCompareClip(url: compareClipURL, syncTo: player)
            if compareClipURL != nil, compareMode == .off {
                compareMode = .wipe
            }
        }
    }

    /// Operator display aids (false color/zebra/peaking, desqueeze, punch-in).
    @Published var assist = ViewAssist() {
        didSet {
            pipeline.setViewAssist(assist)
            playbackTap.setViewAssist(assist)
            rawPlayer?.setViewAssist(assist)
            if oldValue.desqueeze != assist.desqueeze {
                settings.desqueezeFactor = assist.desqueeze == 1
                    ? nil : assist.desqueeze
            }
        }
    }

    /// Aspect of the picture currently in the viewer, desqueeze included —
    /// the framelines box must hug the visible image.
    var displayAspect: CGFloat {
        let base: CGFloat
        if viewerMode == .playback, let aspect = playbackAspect {
            base = aspect
        } else if let format = signalFormat, format.height > 0 {
            base = CGFloat(format.width) / CGFloat(format.height)
        } else {
            base = 16.0 / 9.0
        }
        return base * CGFloat(assist.desqueeze)
    }

    /// A reference frame is pinned for live compare (rec mode wipe/blend).
    @Published var referencePinned = false

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
    var currentCube: CubeLUT?
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

    /// DaVinci Resolve's LUT directory — imported LUTs are mirrored into a
    /// TakeShot subfolder there, so the same look is at hand in Resolve.
    nonisolated static var resolveLUTDirectory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent(
                "Application Support/Blackmagic Design/DaVinci Resolve/LUT/TakeShot",
                isDirectory: true)
    }

    enum DuplicateLUTChoice { case replace, keepBoth, skip }

    var lutPreviewOn: Bool {
        get { settings.lutPreviewEnabled ?? false }
        set {
            settings.lutPreviewEnabled = newValue
            // a per-clip "LUT off" left behind earlier must not eat the new
            // explicit enable — that read as "LUT does nothing in playback"
            if newValue, playbackLUTSuppressed { playbackLUTSuppressed = false }
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

    /// LUT intensity (0…1); default 1. Applied immediately (pipeline + tap mix
    /// coefficient only — no .cube re-read, no filter rebuild), persisted
    /// debounced: a settings write per tick re-rendered the window (slider lag).
    var lutIntensity: Double {
        get { live.lutIntensity }
        set {
            let clamped = min(1, max(0, newValue))
            live.lutIntensity = clamped
            pipeline.setLUTIntensity(clamped)
            playbackTap.setLUTIntensity(clamped)
            lutPersistTask?.cancel()
            lutPersistTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled, let self else { return }
                self.settings.lutIntensity = self.live.lutIntensity
            }
        }
    }

    private var lutPersistTask: Task<Void, Never>?

    var cubeCache: (fileName: String, cube: CubeLUT)?

    /// Large audio-channel panel over the player.
    @Published var showAudioPanel = false
    /// Scopes overlay over the player (like the audio panel).
    @Published var showScopesOverlay = false {
        didSet { updateScopesRunning() }
    }
    /// The separate scopes window is open.
    @Published var scopesWindowOpen = false {
        didSet { updateScopesRunning() }
    }
    /// Any scope surface visible (drives the analyzers and the badge tint).
    var showScopes: Bool { showScopesOverlay || scopesWindowOpen }
    /// Route scope analysis to whichever source is actually on screen.
    func updateScopesRunning() {
        pipeline.setScopesEnabled(showScopes && viewerMode == .record)
        playbackTap.setScopesEnabled(showScopes && viewerMode == .playback)
        rawPlayer?.scopesEnabled = showScopes && viewerMode == .playback
        // scopeData is kept on close — reopening shows the last picture
        // immediately instead of flashing "waiting for signal"
    }
    /// A separate playback fullscreen window (not the system app fullscreen).
    @Published var isPlaybackFullscreen = false
    var playbackFullscreenWindow: NSWindow?
    /// Live-signal fullscreen window (player fills the screen in record mode).
    @Published var isLiveFullscreen = false
    var liveFullscreenWindow: NSWindow?

    /// Player for reviewing takes.
    let player = AVPlayer()
    /// ONE transport for the whole app. Each TransportBar used to own a
    /// @StateObject of its own, and the bar appears twice (the footer and the
    /// audio panel overlay): both attached their own end-of-clip observer to the
    /// same player with their own loop flag, so turning loop off in the bar you
    /// could see left the other one still seeking back — the clip kept looping.
    let transport = TransportModel()
    /// Unified playback render (frames from the player → sample-buffer layers).
    let playbackTap = PlaybackFrameTap()
    /// Live capture audio monitor (renderer to a system output).
    let audioMonitor = AudioMonitor()

    private var monitorVolumeBeforeMute: Double = 1

    /// Speaker click in the audio panel: mute/unmute the volume with restore.
    /// It never disables the output path — the slider always stays live.
    func toggleMonitorMute() {
        if !monitorOn {
            monitorOn = true
            if monitorVolume == 0 { setVolume(monitorVolumeBeforeMute, persist: false) }
            return
        }
        if monitorVolume > 0 {
            monitorVolumeBeforeMute = monitorVolume
            // mute is transient: persisting 0 made every launch start silent
            setVolume(0, persist: false)
        } else {
            setVolume(monitorVolumeBeforeMute > 0 ? monitorVolumeBeforeMute : 1,
                      persist: false)
        }
    }

    /// CSV writes go through one serial queue — two detached writers could
    /// finish out of order and an older snapshot would overwrite a newer one.
    nonisolated static let takeLogQueue = DispatchQueue(
        label: "takeshot.takelog", qos: .utility)

    /// Live audio monitoring on/off; persisted — a 100% volume slider with a
    /// crossed-out speaker at every launch read as a bug, not caution.
    @Published var monitorOn = true {
        didSet {
            updateAudioMonitorRouting()
            settings.monitorEnabled = monitorOn
        }
    }

    /// The live feed is only monitored while the viewer is showing it. Without
    /// this the capture audio kept playing over a clip in playback — two sound
    /// sources at once, and the operator hears the room instead of the take.
    /// `monitorOn` stays the operator's preference and is not overwritten.
    private func updateAudioMonitorRouting() {
        let live = monitorOn && viewerMode == .record
        pipeline.setAudioMonitorEnabled(live)
        if !live { audioMonitor.stop() }
    }

    /// One volume for the live monitor and the player: switching rec↔playback
    /// must not change loudness. Applied immediately, persisted debounced —
    /// writing settings on every drag tick re-rendered the whole window
    /// (slider lag).
    var monitorVolume: Double {
        get { live.volume }
        set { setVolume(newValue) }
    }

    var playbackVolume: Double {
        get { live.volume }
        set { setVolume(newValue) }
    }

    private func setVolume(_ newValue: Double, persist: Bool = true) {
        live.volume = newValue
        audioMonitor.volume = Float(newValue)
        player.volume = Float(newValue)
        // dragging the volume up implies "I want to hear it" (live monitor only)
        if newValue > 0, !monitorOn, isCapturing, viewerMode == .record {
            monitorOn = true
        }
        volumePersistTask?.cancel()
        guard persist else { return }
        volumePersistTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            self.settings.monitorVolume = self.live.volume
        }
    }

    private var volumePersistTask: Task<Void, Never>?

    // MARK: - external monitor output

    /// The selected external display (by displayID); nil — off.
    @Published var externalDisplayID: CGDirectDisplayID? {
        didSet {
            guard oldValue != externalDisplayID else { return }
            updateExternalWindow()
        }
    }
    var externalWindow: NSWindow?

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

    /// Playback audio output (also used by the live monitor).
    var playbackOutputUID: String? {
        get { settings.playbackAudioDeviceUID }
        set {
            settings.playbackAudioDeviceUID = newValue
            player.audioOutputDeviceUniqueID = newValue
            audioMonitor.outputDeviceUID = newValue
        }
    }

    /// RAW codecs played by our own engine, not AVPlayer.
    nonisolated static let rawExtensions: Set<String> = ["braw", "r3d"]

    /// A folder of .dng frames = one CinemaDNG clip.
    nonisolated static func isCinemaDNGFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path,
                                             isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        return !DNGSequenceSource.frameURLs(in: url).isEmpty
    }

    /// The engine for a loaded RAW clip (nil — AVPlayer/photo content).
    @Published var rawPlayer: RawPlayerModel?
    /// Why the RAW clip couldn't be opened (SDK missing, bad file).
    @Published var rawPlayerError: String?

    // MARK: - markers

    /// Markers collected while the current take is recording.
    var recordingMarkers: [TakeMarker] = []
    var recordingStartDate: Date?

    /// Markers of the clip in the player (transport ticks).
    var playbackMarkers: [TakeMarker] {
        guard let url = playbackURL else { return [] }
        return takes.first { $0.url == url }?.markers ?? []
    }

    /// Current playback position in seconds (marker navigation).
    var playbackPositionSeconds: Double {
        if let raw = rawPlayer {
            return Double(raw.currentFrame) / max(1, raw.frameRate)
        }
        return max(0, player.currentTime().seconds)
    }

    /// Freshly recorded take / saved still — the list flashes a border on it.
    @Published var recentlyAddedURL: URL?
    var recentHighlightTask: Task<Void, Never>?

    /// One-shot flag: the transport enables looping when the replayed clip loads.
    var replayLoopRequested = false

    // MARK: - playback info for the player badges

    /// Resolution + fps of the loaded clip ("1920x1080 25p"); nil while loading.
    @Published var playbackFormatText: String?
    /// Start TC from the file's timecode track (nil — none).
    @Published var playbackStartTC: Timecode?
    /// Aspect ratio of the loaded clip (nil while loading / images).
    @Published var playbackAspect: CGFloat?
    /// Set from CaptureController+Playback when a clip loads.
    var playbackFPS: Double = 25

    /// Playback position as timecode (start TC + elapsed at the file's fps).
    var playbackTimecodeText: String {
        if let raw = rawPlayer {
            return raw.timecodeText
        }
        let elapsed = max(0, player.currentTime().seconds)
        let fps = max(1, playbackFPS)
        let frames = Int((elapsed * fps).rounded(.down))
        guard let start = playbackStartTC else {
            let total = Int(elapsed)
            let ff = frames % Int(fps.rounded())
            return String(format: "%02d:%02d:%02d:%02d",
                          total / 3600, (total / 60) % 60, total % 60, ff)
        }
        var tc = start
        tc.fps = Int(fps.rounded())
        return Timecode(frameNumber: start.frameNumber + frames,
                        fps: tc.fps, isDropFrame: start.isDropFrame).description
    }

    @Published var settings = CaptureSettings.loaded() {
        didSet {
            settings.save()
            // volume slider ticks land here too — only re-apply localization on
            // an actual language change (Bundle lookups hit the disk), and only
            // push the pipeline config when something it reads has changed
            if oldValue.appLanguage != settings.appLanguage {
                L10n.apply(appLanguage)
            }
            var irrelevant = oldValue
            irrelevant.monitorVolume = settings.monitorVolume
            if irrelevant != settings {
                pushConfig()
            }
            if oldValue.monitorDeviceID != settings.monitorDeviceID {
                rebuildPlayout()
            }
            if oldValue.destinationPath != settings.destinationPath {
                resetLibraryForNewDestination()
                startFolderWatcher()
            }
            if oldValue.forcedInputMode != settings.forcedInputMode
                || oldValue.forcedInputRGB != settings.forcedInputRGB
                || oldValue.tenBitCapture != settings.tenBitCapture {
                restartCapture()
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

    /// UI language; English by default.
    var appLanguage: AppLanguage {
        get { settings.appLanguage.flatMap(AppLanguage.init(rawValue:)) ?? .english }
        set { settings.appLanguage = newValue.rawValue }
    }

    let pipeline: CapturePipeline

    let backend: AggregateBackend

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
        audioMonitor.outputDeviceUID = stored.playbackAudioDeviceUID
        // 0 in old saves came from the mute button, not a chosen level
        let storedVolume = (stored.monitorVolume ?? 1) > 0
            ? (stored.monitorVolume ?? 1) : 1
        audioMonitor.volume = Float(storedVolume)
        live.volume = storedVolume
        live.lutIntensity = stored.lutIntensity ?? 1
        monitorOn = stored.monitorEnabled ?? true
        assist.desqueeze = stored.desqueezeFactor ?? 1
        player.volume = Float(storedVolume)
        transport.attach(player) // one attachment for the app's lifetime
        bindPipeline()
        playbackTap.setLiveBufferProvider { [pipeline] in
            pipeline.currentPreviewBuffer()
        }
        refreshDevices() // selecting the first device starts capture via didSet
        startFolderSync()
        refreshNameCollision()
        applyLetterboxColor()
        reloadLUTList()
        // the persisted LUT + "apply to preview" must take effect immediately —
        // without this the checkbox showed enabled while nothing was applied
        rebuildLUT()
        rebuildPlayout()
        startDiskWatch()
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
        set {
            settings.playerBackgroundHex = newValue.hexString
            applyLetterboxColor()
        }
    }

    /// The Metal preview letterboxes internally — keep its bars in the chosen
    /// backdrop color (they used to be transparent with the old video layer).
    func applyLetterboxColor() {
        let ns = NSColor(playerBackground).usingColorSpace(.sRGB) ?? .black
        let ci = CIColor(red: ns.redComponent, green: ns.greenComponent,
                         blue: ns.blueComponent)
        pipeline.setPreviewLetterbox(ci)
        playbackTap.setLetterbox(ci)
        rawPlayer?.setLetterbox(ci)
    }

    /// Control accent color; white by default.
    var accentColor: Color {
        get { settings.accentHex.flatMap(Color.init(hex:)) ?? Color(hex: "#FFFFFF")! }
        set { settings.accentHex = newValue.hexString }
    }

    /// Reset only the UI colors to defaults.
    func resetInterface() {
        settings.playerBackgroundHex = nil
        settings.appBackgroundHex = nil
        settings.accentHex = nil
        settings.appearance = nil
        panelSide = "right"
        applyLetterboxColor()
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
    func applyNamingPreset(_ preset: NamingPreset) {
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

    // MARK: - multicam

    /// Extra cameras (the first/main one lives in this controller).
    @Published var extraChannels: [CameraChannel] = []
    /// Multicam on (demo adds a second camera; on hardware — the other boards).
    @Published var multicamOn = false

    /// All cameras for the preview grid: main (nil channel) + extras.
    var allCameraLabels: [String] {
        [settings.cameraLabel] + extraChannels.map(\.camLabel)
    }

    // MARK: - capture control

    /// Input mode names of the selected DeckLink (for the Settings picker).
    var selectedDeviceInputModes: [String] {
        guard let id = selectedDeviceID, id.hasPrefix("decklink:") else { return [] }
        return DeckLinkBackendAdapter.inputModeNames(
            deviceID: String(id.dropFirst("decklink:".count)))
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

    /// The metadata log URL (for "show in Finder").
    var takeLogURL: URL {
        destinationRoot.appendingPathComponent(TakeLogExporter.fileName)
    }

    /// The record root folder (for the "open folder" button).
    var destinationRoot: URL {
        URL(fileURLWithPath: (settings.destinationPath as NSString).expandingTildeInPath)
    }

    // MARK: - folder sync (Other content)

    nonisolated static let videoExtensions: Set<String> =
        ["mov", "mp4", "mxf", "m4v", "avi", "braw", "r3d"]
    nonisolated static let imageExtensions: Set<String> =
        ["jpg", "jpeg", "png", "heic", "tif", "tiff", "dng", "arw", "cr2", "webp"]

    var folderWatcher: DispatchSourceFileSystemObject?
    var folderRescanScheduled = false

    /// Paths already checked for the TakeShot tag (so we don't re-read metadata).
    var scannedPaths: Set<String> = []

    /// Bumped whenever the library is reset (a new destination folder). A scan
    /// that started against the old folder carries the old value and discards
    /// itself instead of pouring the previous folder's takes into the new one.
    var libraryGeneration = 0
    /// A scan is walking the folder or classifying its results.
    var scanInFlight = false
    /// The folder changed while a scan was running — rescan when it lands.
    var rescanWhenIdle = false

    var busyRescanScheduled = false

    /// Takes whose files have left the record folder. They are gone from the
    /// panel but stay in the log, so moving footage off the card does not erase
    /// the day's metadata. Cleared when the destination itself changes.
    var retiredTakes: [Take] = []

    var thumbnailsInFlight: Set<Take.ID> = []
    var otherThumbsInFlight: Set<URL> = []

    /// Decoded thumbnails, least-recently-used first. A busy day is ~500 takes
    /// and each decoded 256x144 image pins ~150 KB, so the cache is bounded and
    /// cells re-request what was evicted when they scroll back into view.
    var thumbnailLRU: [Take.ID] = []
    static let thumbnailCacheLimit = 120

}

// MARK: - CaptureBackendDelegate (callbacks from capture threads — straight into the pipeline)

extension CaptureController: CaptureBackendDelegate {
    nonisolated func backend(_ backend: CaptureBackend, didDetectFormat format: CaptureFormat) {
        pipeline.handleFormat(format)
    }

    nonisolated func backend(_ backend: CaptureBackend, didReceive frame: CapturedFrame) {
        pipeline.handleFrame(frame)
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
