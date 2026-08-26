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
        didSet { applySelectedDevice(from: oldValue) }
    }
    @Published var isCapturing = false
    @Published var isRecording = false
    @Published var signalPresent = true
    @Published var signalFormat: CaptureFormat?
    /// What the live signal says its code values mean, after the operator's HDR
    /// setting has had its say. `.sdr` for everything that is not a PQ or HLG
    /// source, so nothing in the UI changes for a signal that is not HDR.
    ///
    /// @Published rather than on `live`: it changes when the CAMERA changes,
    /// which is a handful of times a shift, not per frame.
    @Published var signalColorimetry = WireColorimetry.sdr
    /// How many audio channels the CURRENT signal is carrying; 0 when nothing is
    /// flowing. The count of `live.audioLevels`, republished at the rate it
    /// actually changes.
    ///
    /// @Published here rather than read off `live` at the point of use, and the
    /// difference is the whole reason it exists: the meters arrive ~25 times a
    /// second and the channel COUNT changes when the signal does, a handful of
    /// times a shift. A menu that read `live.audioLevels.count` would have to
    /// observe `live`, which is what `LiveSignal` was extracted to stop views
    /// doing (see its comment: ~1 CPU core of SwiftUI layout).
    ///
    /// It is what the LTC channel picker offers, so it is also a promise: a
    /// channel in that menu is one the decoder can actually be pointed at.
    @Published var audioChannelCount = 0
    /// Per-frame values (TC/meters) — deliberately NOT @Published here; views
    /// that show them observe `live` so the rest of the UI stays still.
    let live = LiveSignal()
    /// The analysed frame the scopes draw, on its own publisher: it arrives at
    /// a fraction of the rate `live` does, and the scopes panel is the most
    /// expensive body in the app to re-run (see `ScopeFeed`).
    let scopes = ScopeFeed()
    @Published var takes: [Take] = []
    /// Take preview frames for thumbnail mode.
    @Published var thumbnails: [Take.ID: NSImage] = [:]
    /// VANC packet stats for the monitor window.
    @Published var vancStats: [VancPacketStat] = []
    /// Roll (reel/media). Changing the roll resets the clip number.
    @Published var roll: String = "001" {
        didSet { applyRollChange(from: oldValue) }
    }
    @Published var nextTakeNumber: Int = 1 {
        didSet {
            pushConfig()
            refreshNameCollision()
        }
    }

    // MARK: - the slate (creative metadata, see +Slate)

    /// Scene the NEXT take will be slated with. Creative, not technical: it
    /// goes inside the .mov and into every export, and it restarts the scene's
    /// take numbering when it changes.
    @Published var scene: String = "" {
        didSet { applySceneChange(from: oldValue) }
    }
    /// Shot / setup letter of the next take.
    @Published var shot: String = "" {
        didSet {
            pushConfig()
            refreshNameCollision()
        }
    }
    /// The take number inside the scene, when the operator has taken it over;
    /// nil — follow the clip counter.
    ///
    /// Optional rather than a plain Int because "not overridden" is a real
    /// state with its own behaviour: an unslated day must keep exporting the
    /// clip counter it always did, and only an operator who has actually
    /// started logging scenes gets numbering that restarts under them.
    @Published var slateTakeOverride: Int? {
        didSet { pushConfig() }
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
    /// Pixel size of the stills in Other content — what a photo shows where a
    /// video shows its length, so the two are told apart at a glance.
    @Published var otherPixelSizes: [URL: CGSize] = [:]
    /// Markers on clips that are not takes, keyed by FILE NAME.
    ///
    /// Keyed like `TransportModel.rangesByFile` and for the same reason: the
    /// sidecar beside the footage is keyed by name, and these clips have no
    /// `Take` to hang anything off. A take's markers stay on the take — they are
    /// part of what the EDL, the ALE and the shift report are built from — so
    /// this is the second half of one store, not a replacement for the first.
    @Published var otherMarkers: [String: [TakeMarker]] = [:]
    /// Sticky alarm: recording-integrity problems (writer failure, disk low,
    /// lost takes) must NOT vanish after five seconds like a toast. Cleared
    /// by the operator or by the next successful take start.
    @Published var persistentAlert: String?

    /// Error toast: pops up over the footer and dismisses itself after a few
    /// seconds (see `+Toasts` for the timers).
    @Published var lastError: String? {
        didSet { scheduleErrorDismiss() }
    }
    var errorDismissTask: Task<Void, Never>?
    /// Neutral info toast (grab saved etc.) — green, self-dismissing.
    @Published var lastNotice: String? {
        didSet { scheduleNoticeDismiss() }
    }
    /// Color of the notice on screen; nil — the neutral green. Carries the color
    /// of the thing it is ABOUT: a crew's marker convention IS the color, so an
    /// always-green toast said nothing about the marker it had just placed.
    @Published var lastNoticeTint: Color?
    var noticeDismissTask: Task<Void, Never>?
    /// View mode: live signal or playback of a recording.
    @Published var viewerMode: ViewerMode = .record {
        didSet { applyViewerModeChange() }
    }
    /// What's currently loaded in the player (for highlighting in the list).
    @Published var playbackURL: URL?

    @Published var compareMode: CompareMode = .off {
        didSet {
            pushCompare()
            persistCompareSettings()
        }
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
    /// Difference-mode gain (×1/×4/×16 — small differences are invisible
    /// unamplified). Persisted with the mode, see `persistCompareSettings`.
    @Published var differenceGain: DifferenceGain = .x1 {
        didSet {
            pushCompare()
            persistCompareSettings()
        }
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

    /// What has already been offloaded, kept between launches. Owned here so
    /// the sheet can show it the moment it opens and a finished run can append
    /// to it without the sheet being on screen at all.
    let offloadHistory = OffloadHistoryStore()

    // MARK: - dailies (see +Dailies)

    /// One-line dailies status for the takes panel ("Dailies 2/14"); nil when
    /// nothing is running. Separate from `offloadStatus` because the two jobs
    /// are independent and can legitimately run at once.
    @Published var dailiesStatus: String?
    /// The dailies sheet is up.
    @Published var dailiesSheetPresented = false
    /// Burn-in choices, the batch and the running transcode queue. Owned here
    /// for the offload model's reasons: the run outlives the sheet, the panel
    /// strip reads its status — and the RECORDING state has to reach it
    /// whether the sheet is on screen or not (see `handleRecState`).
    let dailies = DailiesQueueModel()
    // MARK: - cards that mount while the app is running (see +CardWatch)

    /// The card the operator is being ASKED about. Never a card being copied:
    /// a mount starts nothing on its own, and this is the whole feature — the
    /// owner's one condition on it was that a card must never begin copying
    /// itself.
    @Published var cardOffer: CardCandidate?
    /// Cards that mounted mid-take. Nothing may contend with a take, so the
    /// prompt waits here and goes up when the take closes.
    var deferredCardOffers: [CardCandidate] = []
    /// Cards dismissed with Ignore. This session only, deliberately: Ignore
    /// means "not now", and the operator who plugs the card back in tomorrow is
    /// asking a different question. "Never" is the persistent one (see
    /// `offloadedCards`).
    var ignoredCardKeys: Set<String> = []
    /// Every card seen this session, by mount path — how a finished run is
    /// matched back to the card it copied.
    var seenCards: [String: CardCandidate] = [:]
    /// Which cards must not be asked about again, across launches.
    let offloadedCards = OffloadedCardLedger()
    /// Where mount/unmount events come from. Injected for the same reason the
    /// backend list is: the real one installs process-wide NSWorkspace
    /// observers, and no test may depend on what is plugged into the machine
    /// running it.
    let volumeWatch: VolumeWatching

    /// The verify-against-manifest sheet is up.
    @Published var verifySheetPresented = false
    /// Re-reading a disk that was offloaded earlier against the ASC MHL
    /// manifest on it. Owned here for the same reasons the offload is, and it
    /// shares `offloadStatus` and the offload queue — the two are the same job
    /// at two different times and must never run at once on one disk.
    let verify = OffloadVerifyModel()

    /// The mirrors of the viewer — the DeckLink playout output, the NDI source,
    /// the SRT stream and the browsers on the shared encoder — and what the two
    /// network outputs report about themselves. One holder rather than a dozen
    /// properties: this type is a capped inventory and they are one subsystem
    /// (see `DisplayMirrors` and `wireDisplayMirrors`).
    let mirrors = DisplayMirrors()

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
    /// The observer's work is `applyAssistChange` in `+Assist` — where the aids
    /// live — rather than twenty lines inline here: this file is the type's
    /// stored-state inventory, and behaviour belongs in the domain extension
    /// named for it (the same split `settings` already has with
    /// `applySettingsChange`).
    @Published var assist = ViewAssist() {
        didSet { applyAssistChange(from: oldValue) }
    }
    /// The chroma-key eyedropper is waiting for a click on the picture (see
    /// `+ChromaKey`). Published because it changes the pointer and puts a
    /// pick surface over the player.
    @Published var chromaPickArmed = false

    // MARK: - the taught REC indicator (see +VisualRec)

    /// What the operator taught the visual REC trigger. The observer is the one
    /// door to the pipeline and to the settings blob, so a row in the panel
    /// cannot forget either half.
    /// The observer's work is `applyVisualRecChange` in `+VisualRec`, for the
    /// reason `assist` and `settings` do the same.
    @Published var visualRecTeaching = VisualRecTeaching() {
        didSet { applyVisualRecChange(from: oldValue) }
    }
    /// Teaching mode: the box is drawn over the picture and a click moves it.
    ///
    /// Unlike the chroma eyedropper this does NOT disarm on the click — a colour
    /// is one value and a box has a size, so the operator keeps adjusting while
    /// they watch the reading underneath.
    @Published var visualRecTeachArmed = false
    /// The trigger's live reading, at a few hertz and only on change. What makes
    /// the teaching honest: the operator can see the box answer `rolling` while
    /// the camera rolls before they trust a take to it.
    @Published var visualRecReading: VisualRecReading?
    /// What opened the take that is rolling; nil while idle. Shown beside REC on
    /// the picture, so a spurious roll can be diagnosed where it happens.
    @Published var recTrigger: RecTrigger?
    /// The assist popover is open.
    ///
    /// Here rather than in `AssistMenu`'s own `@State` because the eyedropper
    /// has to close it for the duration of a click on the picture and put it
    /// straight back afterwards — see `toggleChromaPick`.
    @Published var showAssistPopover = false
    /// Arming the eyedropper took the popover away, so the pick puts it back.
    var chromaPickReopensAssist = false
    /// File name of the plate loaded behind the key; nil — none. The buffer
    /// itself lives in the display stage, which is the only thing that draws
    /// it; this is what the panel shows.
    @Published var chromaBackgroundImageName: String?
    /// The aids as the preview surfaces are showing them right now, sliders and
    /// zoom gestures included (see `applyAssistPreview` in +Assist).
    let assistLive = AssistLiveState()
    /// Debounced fold of a dragged aid value into `assist`.
    var assistPersistTask: Task<Void, Never>?

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

    /// Where imported looks are kept, and where they are mirrored for Resolve.
    ///
    /// Instance properties over the static paths they are seeded from, for the
    /// same reason the record folder and `UserDefaults` are injected: a suite
    /// that exercises the import flow would otherwise copy its fixtures into
    /// the operator's real Application Support and their real Resolve LUT
    /// folder, and `clearLUTs` would delete the looks they went on set with.
    var lutsDirectory = CaptureController.defaultLUTsDirectory
    var resolveLUTDirectory = CaptureController.defaultResolveLUTDirectory

    /// Imported look files (the Application Support/TakeShot/LUTs folder):
    /// .cube lattices and ASC CDL grades side by side.
    @Published var availableLUTs: [LUTInfo] = []
    var currentCube: CubeLUT?
    /// The active look's ASC CDL parameters, when it came from a .cc/.ccc/.cdl.
    ///
    /// Kept ALONGSIDE the cube it was rasterized into, not instead of it: the
    /// cube is what every render path takes, and the nine numbers are what the
    /// selects EDL writes back out as *ASC_SOP/*ASC_SAT. A cube cannot be
    /// reduced to nine numbers again, so throwing them away at import would
    /// silently cost the colourist the grade.
    var currentCDL: CDLLook?
    /// The current playback file already has the look baked in (com.takeshot.lut tag).
    @Published var playbackFileHasBakedLUT = false
    /// Manual LUT off for the current clip (the look came from the camera, etc.).
    @Published var playbackLUTSuppressed = false {
        didSet { applyPlaybackLUT() }
    }
    /// Debounced persist of the LUT mix (see `lutIntensity` in +LUT).
    var lutPersistTask: Task<Void, Never>?
    /// The last look read off disk. A named type rather than a triple: three
    /// positional members read the same whatever order they are in.
    struct LoadedLook {
        var fileName: String
        var cube: CubeLUT
        var cdl: CDLLook?
    }
    /// The last look read off disk, keyed by file name. Carries the CDL as well
    /// as the cube, so a checkbox flip does not re-parse (or re-rasterize) it.
    var cubeCache: LoadedLook?

    /// Large audio-channel panel over the player.
    ///
    /// One overlay at a time (see `closeOtherPlayerOverlays`): two panels over
    /// the same picture cover it completely, and the second one to open hid the
    /// first one's controls.
    @Published var showAudioPanel = false {
        didSet { applyAudioPanelChange() }
    }
    /// Scopes overlay over the player (like the audio panel).
    @Published var showScopesOverlay = false {
        didSet { applyScopesOverlayChange() }
    }
    /// The separate scopes window is open.
    @Published var scopesWindowOpen = false {
        didSet { updateScopesRunning() }
    }
    /// Move/resize watch on the scopes window (see `+ScopesWindow`). Held so a
    /// window that is closed and reopened replaces it instead of stacking
    /// another pair of observers on the same window.
    let scopesFrame = ScopesFrameWatch()
    /// The digital slate window's state (the sync flash/freeze and the card
    /// fields, all read off this controller — see `SlateModel`). Owned here so
    /// a hold in progress survives the window closing and reopening, and so
    /// the tests reach the same instance the window shows. Lazy because it
    /// captures `self`.
    lazy var slate = SlateModel(controller: self)
    /// The status item in the system menu bar; nil — the setting is off, which
    /// is the default (see `+MenuBar`). Owned here rather than by a view: it
    /// exists precisely when no window does.
    var menuBar: MenuBarPresence?
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
    /// The external (USB) audio source while one is selected and running (see
    /// +AudioInput); nil — the board's embedded audio feeds the pipeline.
    var externalAudioSource: ExternalAudioSource?
    /// Input devices for the Settings picker, refreshed on hot-plug.
    @Published var audioInputDevices: [AudioInputDeviceInfo] = []
    /// The pipeline is being fed by the external source right now — what the
    /// channels panel and Settings state as the live source.
    @Published var externalAudioActive = false
    /// The hot-plug watcher is installed once, on first use (see +AudioInput).
    var audioInputWatchStarted = false
    /// Level to restore when the speaker button un-mutes (see +Audio).
    var monitorVolumeBeforeMute: Double = 1
    /// Channel selection to come back to when the bank key leaves mix-only (see
    /// `toggleAudioChannelBank`). Session state, like the level above: the mask
    /// itself is what gets persisted, and 0xFFFF is how "all channels" is spelled.
    var audioMaskBeforeMixOnly: Int = 0xFFFF

    /// Live audio monitoring on/off; persisted — a 100% volume slider with a
    /// crossed-out speaker at every launch read as a bug, not caution.
    @Published var monitorOn = true {
        didSet {
            updateAudioMonitorRouting()
            settings.audio.monitorEnabled = monitorOn
        }
    }
    /// Debounced persist of the volume slider (see `setVolume` in +Audio).
    var volumePersistTask: Task<Void, Never>?
    /// Debounced persist of the DIM hold — same debounce as the slider beside it
    /// (see `persistDimState` in +Audio).
    var dimPersistTask: Task<Void, Never>?
    /// Debounced persist of the full mute — same debounce again (see
    /// `persistMuteState` in +Audio): the speaker sits beside the meters and is
    /// on a hotkey, so a click must not write settings synchronously.
    var mutePersistTask: Task<Void, Never>?

    /// The selected external display (by displayID); nil — off.
    @Published var externalDisplayID: CGDirectDisplayID? {
        didSet { applyExternalDisplayChange(from: oldValue) }
    }
    var externalWindow: NSWindow?

    /// The engine for a loaded RAW clip (nil — AVPlayer/photo content).
    @Published var rawPlayer: RawPlayerModel?
    /// Sync-play of 2–4 takes side by side (nil — normal playback). Owned here
    /// like the RAW engine: the mode outlives any render of the grid, and
    /// entry/exit live in `+SyncPlay`.
    @Published var syncPlay: SyncPlayModel?
    /// Why the RAW clip couldn't be opened (SDK missing, bad file).
    @Published var rawPlayerError: String?

    /// Markers collected while the current take is recording.
    var recordingMarkers: [TakeMarker] = []
    var recordingStartDate: Date?

    // MARK: - web remote (see +Remote)

    /// The browser remote's server; nil — off, which is the default.
    var remoteServer: RemoteServer?
    /// The port the listener actually bound; 0 — not listening. Published
    /// because it is the only honest answer to "is the remote up?" in
    /// Settings: the configured port is a wish, this is what happened.
    @Published var remoteBoundPort: Int = 0
    /// Feeds the remote its status; cancelled with the server.
    var remoteStatusTask: Task<Void, Never>?
    /// Scales and JPEG-encodes preview frames for the camera grid. Exists
    /// only while a phone is actually watching — the server reports demand
    /// and `setRemoteMultiviewActive` builds and drops it on that edge — so
    /// an idle set costs no encode work (see +RemoteMultiview).
    var remoteMultiviewEncoder: MultiviewEncoder?
    /// Free space on the record volume, GB; -1 — unreadable. Sampled a few
    /// times a minute rather than per push: the status goes out four times a
    /// second and a volume query is a syscall on the MainActor.
    var remoteDiskFreeGB: Double = -1
    /// Take posters already encoded, by take. The script page asks for one per
    /// row, so the bytes are kept rather than re-encoded per request; the
    /// image behind them never changes once decoded (see +RemoteStatus).
    var remotePosterJPEG: [Take.ID: Data] = [:]
    /// Insertion order for the cache above, oldest first — bounded like the
    /// thumbnail cache it is built from.
    var remotePosterOrder: [Take.ID] = []

    /// Freshly recorded take / saved still — the list flashes a border on it.
    @Published var recentlyAddedURL: URL?
    var recentHighlightTask: Task<Void, Never>?

    // MARK: - takes-panel selection

    /// What the operator has clicked in the takes panel, by URL — takes and
    /// Other content in one set. The two sections are one list to click through
    /// (sweeping up the day's rejects, nobody cares which section a file landed
    /// in) and Delete has to mean the same thing in both. See `+Takes`.
    @Published var selectedItems: Set<URL> = []
    /// Where a shift-click measures its range from: the last plain click.
    var selectionAnchor: URL?
    /// The Trash confirmation is asked for in two places (the Delete key on the
    /// panel, the context menu) and answered in one, so the flag lives with the
    /// selection rather than in either view.
    @Published var trashPromptOpen = false

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

    /// Where input audio devices come from (see +AudioInput). Injected for
    /// the same reason the backend list is: the real provider enumerates and
    /// opens the machine's audio hardware, and no headless test may depend on
    /// what happens to be plugged into the runner.
    let audioInputs: AudioInputDeviceProviding

    /// Where the app's own preferences live. `.standard` in the app; tests hand
    /// in a scratch suite so a headless controller cannot read or overwrite the
    /// operator's real settings (record folder included).
    let defaults: UserDefaults

    /// `backends` defaults to the shipping set. Tests pass the demo source
    /// alone: constructing the DeckLink adapter installs a process-wide
    /// hot-plug callback and adopts whatever board is attached to the machine
    /// running the tests, which no headless test can be deterministic against.
    init(backends: [(String, CaptureBackend)]? = nil,
         defaults: UserDefaults = .standard,
         audioInputs: AudioInputDeviceProviding? = nil,
         volumeWatch: VolumeWatching? = nil) {
        self.defaults = defaults
        self.audioInputs = audioInputs ?? SystemAudioInputProvider()
        self.volumeWatch = volumeWatch ?? WorkspaceVolumeWatch()
        self.backend = AggregateBackend(children: backends ?? Self.shippingBackends())
        let stored = CaptureSettings.loaded(from: defaults)
        self.settings = stored
        self.panelSide = defaults.string(forKey: "panelSide") ?? "right"
        self.pipeline = CapturePipeline(config: .init(
            settings: stored, roll: "001", takeNumber: 1))

        self.backend.delegate = self
        completeStartup(stored: stored)
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
