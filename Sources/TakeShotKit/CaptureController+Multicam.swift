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
        defer { refreshRemoteMultiviewTaps() }
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
            // hardware: each OTHER DeckLink board is its own channel
            let others = devices.filter {
                $0.id.hasPrefix("decklink:") && $0.id != selectedDeviceID
            }
            var channels: [CameraChannel] = []
            var letter = nextLetter
            for device in others {
                let rawID = String(device.id.dropFirst("decklink:".count))
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
                    lastError = Self.tagged(error.localizedDescription,
                                            source: device.name)
                }
                letter = FieldStepper.stepLetter(letter, by: 1)
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
