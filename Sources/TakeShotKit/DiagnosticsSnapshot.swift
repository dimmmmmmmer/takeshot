import CaptureCore
import Foundation

/// Everything the diagnostic bundle says about the app, taken in one pass on
/// the main actor and then handed off as a value.
///
/// A value, not a reference to the controller, for two reasons. The bundle is
/// written on a background task — reading live controller state from there
/// would be exactly the data race the rest of this codebase is careful about —
/// and the snapshot must describe the moment the operator hit the menu item,
/// not whatever the app had drifted to by the time three files were on disk.
///
/// Nothing in here is a secret. There is no field for the remote PIN, so no
/// amount of later editing can accidentally route one into a file (see
/// `RemoteSection`).
struct DiagnosticsSnapshot: Codable, Sendable {
    var generatedAt = Date()
    var app = AppSection()
    var machine = MachineSection()
    var deckLink = DeckLinkSection()
    var capture = CaptureSection()
    var recording = RecordingSection()
    var takes = TakesSection()
    var jobs = JobsSection()
    var remote = RemoteSection()
    /// `CaptureSettings` flattened to strings, secrets dropped and paths
    /// abbreviated — see `DiagnosticsRedaction.settings`.
    var settings: [String: String] = [:]
    /// The app's own windows: identifier, geometry, visibility. No titles — a
    /// window title can carry a clip name, and the take list already says what
    /// is in the folder if the reader wants that.
    var windows: [WindowRow] = []

    // MARK: - sections

    struct AppSection: Codable, Sendable {
        var version = "dev"
        var build = "-"
        /// Stamped into Info.plist by `scripts/bundle-app.sh`; absent in a
        /// `swift run` build, which is itself worth knowing.
        var gitSHA: String?
        var bundleIdentifier: String?
        /// Where the binary is running from. The one path in the bundle that
        /// is about the APP rather than the production, and it matters: a copy
        /// under ~/Documents needs a TCC grant just to read its own resources.
        var bundlePath: String?
        /// The UI language in force, which decides what the operator was
        /// reading when it went wrong.
        var language = "system"
        /// The synthetic demo source is the SELECTED device — i.e. what is on
        /// screen is not a camera. Stated as its own line rather than left to
        /// be inferred from the device ID: "why is the picture wrong" has this
        /// answer more often than it has any other.
        var demoSourceSelected = false
    }

    struct MachineSection: Codable, Sendable {
        var osVersion = ""
        /// "MacBookPro18,3" — the model identifier, not the machine's name.
        /// The name is the operator's ("Ivan's MacBook Pro") and is left out.
        var model = ""
        var architecture = ""
        var physicalMemoryGB = 0.0
        var processorCount = 0
        /// Both of these throttle a capture rig, and both are invisible from
        /// inside the app's own UI — a laptop that is hot or on battery saver
        /// drops frames and looks like a broken board.
        var thermalState = ""
        var lowPowerMode = false
    }

    struct DeckLinkSection: Codable, Sendable {
        var compiledWithSDK = false
        var runtimeLoaded = false
        var frameworkPresent = false
        var desktopVideoVersion: String?
        var diagnosis = DeckLinkDiagnosis.stub
        var diagnosisText = ""
        /// Every device the aggregate backend offers, demo source included —
        /// "the list is empty" and "the list has only the demo source in it"
        /// are different faults.
        var devices: [DeviceRow] = []
        var selectedDeviceID: String?
        var forcedInputMode: String?
        /// The BRAW bridge answers the same shape of question (a Blackmagic
        /// framework loaded at runtime), so it is stated in the same place.
        var brawSDKAvailable = false
        /// …and so does libsrt, for the SRT output. Worth a line of its own
        /// beyond the settings row that already shows it: the whole failure mode
        /// of a network output is invisible, and "which build am I running" is
        /// the first question a report about one has to answer.
        var srtSDKAvailable = false
        /// The libsrt version the runtime reported; nil in a build with no
        /// bridge, or on a machine with none installed.
        var srtRuntimeVersion: String?
        /// …and so does NDI, the other network output. Two lines rather than one
        /// because for NDI they can disagree in a way that matters and is
        /// otherwise baffling: the SDK HEADERS are what a build has or has not,
        /// and the RUNTIME is what a machine has or has not, and a machine with
        /// NDI Tools installed and no SDK reports a version of nothing. That is
        /// the exact state the feature was restored in, so it is the first thing
        /// a report about a missing source has to be able to say.
        var ndiSDKAvailable = false
        /// The libndi version the runtime reported; nil in a build with no
        /// bridge, or on a machine with none installed.
        var ndiRuntimeVersion: String?
    }

    struct DeviceRow: Codable, Sendable {
        var id = ""
        var name = ""
    }

    struct CaptureSection: Codable, Sendable {
        var isCapturing = false
        var signalPresent = false
        var formatName: String?
        var width = 0
        var height = 0
        var frameRate = 0.0
        var timecodeFPS = 0
        var isDropFrame = false
        var isRGB444 = false
        /// Bits per component the board is really delivering, which is not
        /// always what the SIGNAL is sending — a 12-bit RGB or 10-bit YCbCr
        /// format the hardware refuses falls back, and the operator's five-second
        /// notice is long gone by the time a bundle is collected.
        var wireBitDepth = 8
        /// Bits per component the SOURCE says it is sending, off the board's
        /// format-detection flags; nil when it did not say (a forced input mode,
        /// an older DeckLink SDK, or the demo source).
        ///
        /// The pair is the point. Depth follows the signal and nobody chooses it
        /// any more, so a bundle that reported only one number could not tell
        /// "the camera is 10-bit" apart from "the camera is 12-bit and the board
        /// would not open it" — which are the same line of footage and two
        /// completely different conversations.
        var sourceBitDepth: Int?
        var currentTimecode: String?
        /// The setting as stored, and what the levels stage actually does with
        /// it for this signal. The two differ under "auto", which is the mode
        /// most rigs are on.
        var levelsSetting = "auto"
        var levelsEffective = ""
        /// The HDR setting as stored, and what the signal is actually being
        /// treated as. The two differ whenever the operator has forced SDR on a
        /// source that IS reporting PQ or HLG, which is exactly the state
        /// somebody reading a bundle needs to be able to see.
        var hdrSetting = "auto"
        var hdrSignal = "SDR (Rec.709)"
        /// MaxCLL / MaxFALL / mastering-display luminance, as the board reported
        /// them and as the file was tagged. Empty when the signal carried none.
        var hdrDisplayMetadata = ""
        // `tenBitCapture` was reported here, straight off the settings blob.
        // There is no depth setting any more, so a bundle that printed one
        // would be printing a stored value nothing reads — the two depth fields
        // above are what a reader actually needs.
        var detectionMode = ""
        var preRollFrames = 0
        /// The taught REC indicator, in one line — state, box, separation,
        /// margin and its current reading. "not taught" when there is nothing
        /// to say, which is the common case.
        ///
        /// One string rather than five fields because it is read, not queried:
        /// what a bundle needs is a line someone can look at and say "yes, that
        /// could have rolled the take" or "no, it was never armed".
        var visualRec = "not taught"
    }

    struct RecordingSection: Codable, Sendable {
        var recordFolder = ""
        var recordFolderExists = false
        var recordFolderWritable = false
        var volumeName: String?
        var freeSpaceGB: Double?
        var codec = ""
        var health = PipelineHealth()
        /// The sticky alarm, verbatim, if one is up. The single most useful
        /// line in the whole bundle when something has gone wrong.
        var persistentAlert: String?
        var lastError: String?
        var audioSource = "embedded"
        var audioChannelMask: String?
        /// Who chose the mask above, and whether the standby measurement had
        /// answered at the moment the bundle was collected. Both, because a
        /// take recorded on two channels is a different report depending on
        /// whether the app measured that or the operator asked for it — and
        /// "auto, no answer yet" is the third case, where every channel is
        /// recorded (see `AudioChannelDetector`).
        var audioChannelDecision: String?
        var externalAudioActive = false
    }

    struct TakesSection: Codable, Sendable {
        var total = 0
        /// Takes whose files have left the record folder since launch.
        var retired = 0
        /// How many of `recent` were asked for, so a truncated list says so.
        var listed = 0
        var recent: [TakeRow] = []
    }

    struct TakeRow: Codable, Sendable {
        var name = ""
        var recordedAt = Date()
        var durationSeconds = 0.0
        var roll = ""
        var clip = 0
        var startTimecode: String?
        var rating = "none"
        /// The file name carries `_FAILED` — the finalize did not complete and
        /// the take was deliberately renamed rather than re-adopted.
        var failedFinalize = false
        var fileExists = false
        var fileSizeBytes: Int64 = 0
        /// Carries the pipeline's own integrity note when there is one
        /// ("USB audio lost — n packet(s) padded with silence").
        var note: String?
    }

    struct JobsSection: Codable, Sendable {
        var offloadRunning = false
        var offloadStatus: String?
        var offloadSource: String?
        var offloadDestinations: [String] = []
        var verifyRunning = false
        var verifyRoot: String?
        var dailiesRunning = false
        var dailiesStatus: String?
        var dailiesQueued = 0
        var dailiesDestination: String?
    }

    /// The remote server as the app sees it.
    ///
    /// There is no PIN field, on purpose. The PIN is the only credential this
    /// app has, the bundle exists to be sent to someone, and a field that does
    /// not exist cannot be filled in by a later change that was not thinking
    /// about privacy. The port and the client count are what actually diagnose
    /// a remote that is not working.
    struct RemoteSection: Codable, Sendable {
        var enabled = false
        var boundPort = 0
        var configuredPort = 0
        var clientCount = 0
        var multiviewActive = false
        /// Whether a PIN is set at all — a yes/no, never the digits.
        var pinConfigured = false
    }

    struct WindowRow: Codable, Sendable {
        var identifier = ""
        var frame = ""
        var visible = false
    }
}
