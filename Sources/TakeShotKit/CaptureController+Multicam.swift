import CaptureCore
import Foundation

/// The extra cameras. The first one lives in this controller; every other board
/// is a `CameraChannel` of its own, recorded in sync by the same REC.
///
/// Split out of `+Capture`: one camera and several are different jobs, and this
/// one is only ever entered from the multicam switch.
extension CaptureController {
    /// All cameras for the preview grid: main (nil channel) + extras.
    var allCameraLabels: [String] {
        [settings.naming.cameraLabel] + extraChannels.map(\.camLabel)
    }

    /// The boards in the device list, in the order it has them.
    ///
    /// One list, because three things read it and two of them must agree: the
    /// multicam badge over the player is shown by there being more than one,
    /// `setMulticam` starts a channel on each of the OTHERS, and the hardware
    /// monitor picker offers all of them. Three spellings of "which of these is
    /// a board" is a lit button that adds no camera.
    var deckLinkDevices: [CaptureDeviceInfo] {
        devices.filter { $0.id.hasPrefix(Self.deckLinkPrefix) }
    }

    /// Whether a second camera is on offer — what the player's multicam badge
    /// is shown by.
    ///
    /// Boards only, deliberately: the demo source CAN start a second mock
    /// camera (that is how the grid is exercised with no hardware), but it is
    /// in every build's device list, so a badge that counted it would put a
    /// multicam button on the player of every downloaded copy of the app.
    var multicamOffered: Bool { deckLinkDevices.count > 1 }

    /// Which extra board becomes which camera.
    ///
    /// The letters follow the main camera's — with A on the selected board the
    /// others become B, C, D, in device order — and they are not cosmetic: the
    /// label goes into `NamingEngine`, so it is in the FILE NAMES. A board that
    /// changed letter between two sessions of the same shoot is a day of
    /// footage that will not sort against the other day's.
    ///
    /// Pure, and separate from `setMulticam`, because starting a channel means
    /// constructing a `DeckLinkBackendAdapter` — which installs a process-wide
    /// hot-plug callback and adopts whatever board is attached, and is the one
    /// thing `ControllerHarness` exists to keep out of the suite.
    static func multicamPlan(boards: [CaptureDeviceInfo], selected: String?,
                             mainLabel: String)
        -> [(deviceID: String, label: String)] {
        var letter = FieldStepper.stepLetter(mainLabel, by: 1)
        var plan: [(deviceID: String, label: String)] = []
        for board in boards where board.id != selected {
            plan.append((String(board.id.dropFirst(deckLinkPrefix.count)), letter))
            letter = FieldStepper.stepLetter(letter, by: 1)
        }
        return plan
    }

    /// How a DeckLink device id is spelled in the device list.
    static let deckLinkPrefix = "decklink:"

    func toggleMulticam() {
        setMulticam(!multicamOn)
    }

    func setMulticam(_ on: Bool) {
        for channel in extraChannels { channel.stop() }
        extraChannels.removeAll()
        multicamOn = on
        // The multiview taps follow the channel list in both directions: a
        // camera that joined starts feeding its tile, and switching multicam
        // off leaves only the main tap (the stopped channels' pipelines went
        // with them). A no-op while nobody is watching.
        defer { refreshMonitorTaps() }
        guard on else { return }

        let nextLetter = FieldStepper.stepLetter(settings.naming.cameraLabel, by: 1)
        if isMockSelected {
            // demo: a second mock camera
            let mock = MockCaptureBackend()
            let channel = CameraChannel(
                camLabel: nextLetter, backend: mock,
                deviceID: MockCaptureBackend.deviceID, settings: settings, roll: roll)
            channel.onTakeFinished = { [weak self] take in self?.appendChannelTake(take) }
            channel.onError = { [weak self] alarm in
                self?.reportPipelineError(alarm, camera: nextLetter)
            }
            try? channel.start() // the mock cannot fail
            extraChannels = [channel]
        } else {
            // hardware: each OTHER DeckLink board is its own channel, under the
            // letter `multicamPlan` gave it
            var channels: [CameraChannel] = []
            for (rawID, letter) in Self.multicamPlan(
                boards: deckLinkDevices, selected: selectedDeviceID,
                mainLabel: settings.naming.cameraLabel) {
                let channel = CameraChannel(
                    camLabel: letter,
                    backend: DeckLinkBackendAdapter(watchesDevices: false),
                    deviceID: rawID, settings: settings, roll: roll)
                channel.onTakeFinished = { [weak self] take in self?.appendChannelTake(take) }
                // `letter` by value: capturing the channel in its own callback
                // would be a retain cycle, and it is the label we want anyway
                channel.onError = { [weak self, letter] alarm in
                    self?.reportPipelineError(alarm, camera: letter)
                }
                do {
                    try channel.start()
                    channels.append(channel)
                } catch {
                    let name = devices.first {
                        $0.id == Self.deckLinkPrefix + rawID
                    }?.name ?? rawID
                    lastError = Self.tagged(
                        BridgeUnavailable(error: error).localizedText,
                        source: name)
                }
            }
            extraChannels = channels
        }
    }
    private func appendChannelTake(_ take: Take) {
        takes.append(take)
        takes.sort { $0.recordedAt < $1.recordedAt }
        exportTakeLog()
        requestThumbnail(for: take)
    }
}
