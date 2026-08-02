import CaptureCore
import Foundation

/// The record-side audio source: the board's embedded audio (the default), or
/// an external Core Audio input — on real sets the mixer's feed often arrives
/// over USB rather than embedded in the SDI/HDMI signal. The choice persists
/// as `CaptureSettings.audioInputDeviceUID`; everything device-facing goes
/// through the injected `audioInputs` provider so the tests drive this whole
/// path with a fake device.
///
/// Failure honesty, in one place: a device missing when it is selected (or at
/// launch, or at REC start) falls back to embedded audio with a visible
/// warning — never a take that silently records no sound. A device that
/// vanishes MID-take must not kill the take: the pipeline keeps video rolling
/// and pads the audio with counted silence (see `+ExternalAudio`), and the
/// source is re-resolved when the take closes.
extension CaptureController {
    /// The selected input device UID (nil — embedded); Settings binds here.
    var audioInputUID: String? {
        get { settings.audioInputDeviceUID }
        set { settings.audioInputDeviceUID = newValue }
    }

    /// From `applySettingsChange`: rebuild only when the choice itself moved.
    func applyAudioInputChange(from oldValue: CaptureSettings) {
        guard oldValue.audioInputDeviceUID != settings.audioInputDeviceUID
        else { return }
        rebuildExternalAudioSource()
    }

    /// Refresh the picker's list and make sure the hot-plug watcher runs.
    /// Called when the Settings pane appears, not at startup: enumerating the
    /// machine's devices is work the app has no business doing until someone
    /// asks to see them (and a selected device installs the watcher itself).
    func refreshAudioInputDevices() {
        startAudioInputWatchIfNeeded()
        audioInputDevices = audioInputs.list()
    }

    private func startAudioInputWatchIfNeeded() {
        guard !audioInputWatchStarted else { return }
        audioInputWatchStarted = true
        audioInputs.startWatching { [weak self] in
            self?.audioInputDevicesChanged()
        }
    }

    /// Hot-plug: refresh the picker, and reattach the configured device if it
    /// just came back while nothing is recording. Mid-take the pipeline is
    /// already padding — the take's channel count is latched, so a source
    /// change waits for it to close (see `reconcileAudioInputAfterTake`).
    func audioInputDevicesChanged() {
        audioInputDevices = audioInputs.list()
        guard let uid = settings.audioInputDeviceUID, externalAudioSource == nil,
              !isRecording,
              audioInputDevices.contains(where: { $0.uid == uid })
        else { return }
        rebuildExternalAudioSource()
    }

    /// (Re)start capture from the configured device, or fall back to embedded
    /// audio with the visible warning.
    func rebuildExternalAudioSource() {
        externalAudioSource?.stop()
        externalAudioSource = nil
        guard let uid = settings.audioInputDeviceUID else {
            activateEmbeddedAudio(warning: nil)
            return
        }
        // the reattach path needs to see the device return
        startAudioInputWatchIfNeeded()
        guard let device = audioInputs.makeCaptureDevice(uid: uid) else {
            activateEmbeddedAudio(warning: L("usb_audio_missing"))
            return
        }
        let source = ExternalAudioSource(device: device)
        // the pipeline hops to its own queue inside handleAudio, so the
        // device's delivery queue never blocks on anything downstream
        let pipeline = self.pipeline
        source.onPacket = { pipeline.handleAudio($0, from: .external) }
        source.onDeviceGone = { [weak self] in
            Task { @MainActor in self?.handleExternalAudioDeviceGone() }
        }
        do {
            try source.start()
        } catch {
            activateEmbeddedAudio(warning: L("usb_audio_missing"))
            return
        }
        externalAudioSource = source
        externalAudioActive = true
        pipeline.setActiveAudioSource(.external,
                                      expectedChannels: device.channelCount)
    }

    /// Back to the board's embedded audio — with the warning when it is a
    /// fallback rather than the operator's choice.
    private func activateEmbeddedAudio(warning: String?) {
        externalAudioActive = false
        pipeline.setActiveAudioSource(
            .embedded, expectedChannels: backend.embeddedAudioChannels)
        if let warning { persistentAlert = warning }
    }

    /// The device vanished. Mid-take: keep the take alive — the pipeline pads
    /// its audio with counted silence and raises the sticky alarm; switching
    /// to embedded mid-take is off the table (the writer's channel count is
    /// latched, and splicing sources would be worse than honest silence).
    /// Idle: fall back to embedded now, visibly.
    func handleExternalAudioDeviceGone() {
        externalAudioSource?.stop()
        externalAudioSource = nil
        audioInputDevices = audioInputs.list()
        if isRecording {
            pipeline.markExternalAudioLost()
        } else {
            activateEmbeddedAudio(warning: L("usb_audio_disconnected"))
        }
    }

    /// After a take closes: if the take outlived its USB device, resolve the
    /// source now — the device came back (reattach) or embedded takes over
    /// with the warning. Called from the REC-state observer.
    func reconcileAudioInputAfterTake() {
        guard settings.audioInputDeviceUID != nil, externalAudioSource == nil
        else { return }
        rebuildExternalAudioSource()
    }

    /// A take is starting with a USB source configured but not running: the
    /// pipeline already fell back to embedded, and the warning must be up
    /// WHILE the take records — a clean REC start clears the alarm banner,
    /// which would otherwise silently swallow the fallback notice.
    func warnIfAudioFellBackAtRecStart() {
        guard settings.audioInputDeviceUID != nil, !externalAudioActive
        else { return }
        persistentAlert = L("usb_audio_missing")
    }

    /// What the channels panel and Settings state as the live source.
    var audioSourceStatusText: String {
        guard externalAudioActive, let source = externalAudioSource else {
            return L("audio_source_embedded_live")
        }
        let name = audioInputDevices.first { $0.uid == source.deviceUID }?.name
            ?? source.deviceUID
        return L("audio_source_usb_live", name, source.channelCount)
    }
}
