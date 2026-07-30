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
///
/// This file holds the state itself — everything the type DOES lives in the
/// domain extensions (`+Capture`, `+Playback`, `+Viewer`, `+Compare`, `+LUT`,
/// `+Markers`, `+Library`, `+Takes`, `+Thumbnails`, `+Offload`, `+Settings`,
/// `+Audio`, `+Naming`, `+Windows`).
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
    /// What's currently loaded in the player (for highlighting in the list).
    @Published var playbackURL: URL?

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

    /// One-line offload status for the takes panel ("Offload 41/128"); nil when
    /// nothing is running. The detail lives in the sheet.
    @Published var offloadStatus: String?

    // MARK: - DIT offload (see +Offload)

    /// The offload sheet is up.
    @Published var offloadSheetPresented = false
    /// Source, destination list and the running offload itself. Owned here
    /// rather than by the sheet: the run outlives any render of it, and the
    /// takes panel reads its status line.
    let offload = OffloadSheetModel()

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

    /// A reference frame is pinned for live compare (rec mode wipe/blend).
    @Published var referencePinned = false

    /// Takes-panel position (left/right) — reactive for all windows.
    /// Seeded from `defaults` in init; the observer never fires for that
    /// assignment, so a fresh controller does not write back what it just read.
    @Published var panelSide: String = "right" {
        didSet { defaults.set(panelSide, forKey: "panelSide") }
    }
    /// Hotkey manager (for the fullscreen windows' environment).
    weak var hotkeysRef: HotkeyManager?
    /// Actual height of the window-button area (title bar hidden, buttons over content).
    @Published var windowTopInset: CGFloat = 26

    /// Imported LUT files (the Application Support/TakeShot/LUTs folder).
    @Published var availableLUTs: [LUTInfo] = []
    var currentCube: CubeLUT?
    /// The current playback file already has the look baked in (com.takeshot.lut tag).
    @Published var playbackFileHasBakedLUT = false
    /// Manual LUT off for the current clip (the look came from the camera, etc.).
    @Published var playbackLUTSuppressed = false {
        didSet { applyPlaybackLUT() }
    }
    /// Debounced persist of the LUT mix (see `lutIntensity` in +LUT).
    var lutPersistTask: Task<Void, Never>?
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
    /// Level to restore when the speaker button un-mutes (see +Audio).
    var monitorVolumeBeforeMute: Double = 1

    /// Live audio monitoring on/off; persisted — a 100% volume slider with a
    /// crossed-out speaker at every launch read as a bug, not caution.
    @Published var monitorOn = true {
        didSet {
            updateAudioMonitorRouting()
            settings.monitorEnabled = monitorOn
        }
    }
    /// Debounced persist of the volume slider (see `setVolume` in +Audio).
    var volumePersistTask: Task<Void, Never>?

    /// The selected external display (by displayID); nil — off.
    @Published var externalDisplayID: CGDirectDisplayID? {
        didSet {
            guard oldValue != externalDisplayID else { return }
            updateExternalWindow()
        }
    }
    var externalWindow: NSWindow?

    /// The engine for a loaded RAW clip (nil — AVPlayer/photo content).
    @Published var rawPlayer: RawPlayerModel?
    /// Why the RAW clip couldn't be opened (SDK missing, bad file).
    @Published var rawPlayerError: String?

    /// Markers collected while the current take is recording.
    var recordingMarkers: [TakeMarker] = []
    var recordingStartDate: Date?

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

    @Published var settings: CaptureSettings {
        didSet { applySettingsChange(from: oldValue) }
    }

    let pipeline: CapturePipeline

    let backend: AggregateBackend

    /// Where the app's own preferences live. `.standard` in the app; tests hand
    /// in a scratch suite so a headless controller cannot read or overwrite the
    /// operator's real settings (record folder included).
    let defaults: UserDefaults

    /// What the app itself runs on: the DeckLink bridge plus the demo source.
    /// The demo source is always last; when a real board appears the app
    /// switches to it automatically (see refreshDevices).
    static func shippingBackends() -> [(String, CaptureBackend)] {
        [("decklink", DeckLinkBackendAdapter()),
         ("mock", MockCaptureBackend())]
    }

    /// `backends` defaults to the shipping set. Tests pass the demo source
    /// alone: constructing the DeckLink adapter installs a process-wide
    /// hot-plug callback and adopts whatever board is attached to the machine
    /// running the tests, which no headless test can be deterministic against.
    init(backends: [(String, CaptureBackend)]? = nil,
         defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let backend = AggregateBackend(children: backends ?? Self.shippingBackends())
        self.backend = backend

        let stored = CaptureSettings.loaded(from: defaults)
        self.settings = stored
        self.panelSide = defaults.string(forKey: "panelSide") ?? "right"
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
        // The offload model reports back through the controller (status line,
        // toast, sticky alarm), so it is wired for the controller's lifetime and
        // not at the moment the sheet happens to open.
        offload.attach(to: self)
    }

    // MARK: - multicam

    /// Extra cameras (the first/main one lives in this controller).
    @Published var extraChannels: [CameraChannel] = []
    /// Multicam on (demo adds a second camera; on hardware — the other boards).
    @Published var multicamOn = false

    // MARK: - folder sync (Other content)

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
}
