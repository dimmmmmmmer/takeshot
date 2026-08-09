import CaptureCore
import Foundation

/// The NDI output, from the controller's side: announcing the source, taking it
/// down, and what the operator is told when it cannot be had.
///
/// The frames come off the SAME display-mirror slot the hardware monitor rides
/// (see `wireDisplayMirrors`), so NDI carries the DECORATED frame — the picture
/// the operator and the director are looking at, aids and chroma key included.
/// That is the hardware monitor's case, not the phone grid's: the grid gets the
/// clean frame because it is a crew monitoring surface where the operator's own
/// tools would lie to it, and an NDI feed exists to replace a cable to a
/// director's monitor. Whoever watches it is watching over the operator's
/// shoulder, and should see the same picture.
///
/// Nothing here exists while the switch is off: `mirrors.ndi` is nil, the display
/// slot holds no NDI consumer, and the SDK has not even been loaded — the
/// runtime dlopen happens on the first `unavailableReason` read, which is the
/// moment the operator asks for the feature.
///
/// **Picture only, on purpose, and here is the door.** NDI carries audio, and an
/// iPad with no sound is half a monitor — but the only stereo feed the pipeline
/// produces is `onMonitorAudio`, and it is wrong for this twice over. It is a
/// single slot already owned by `AudioMonitor` (the room speakers), and it is
/// gated on `monitorEnabled`, so an NDI feed hung off it would make the sound on
/// a director's iPad a side effect of whether the operator has the cart's
/// speakers up — and forcing that switch on to get audio is precisely the bug
/// `ControllerHarness` goes out of its way to prevent. Sending sound therefore
/// needs a SECOND tap in `CapturePipeline+Audio`, independent of the monitor and
/// of its channel mask, plus a conversion into what NDI wants (planar float,
/// `NDIlib_FourCC_audio_type_FLTP`, through `NDIlib_send_send_audio_v3`) done on
/// the mirror's queue rather than the capture queue. That is a path with a
/// timing contract of its own and none of it can be checked without the headers
/// and a receiver on the network, so it is not being guessed at here. The
/// picture is the half that replaces a cable.
extension CaptureController {
    /// How long a name edit settles before the source is re-announced. The field
    /// writes on every keystroke and NDI has no way to rename a live sender, so
    /// each write would otherwise put another source in every receiver's list on
    /// the shoot — "MyFil", then "MyFilm". The same debounce, for the same kind
    /// of reason, as the volume slider's persist.
    static let ndiRenameDebounce = Duration.milliseconds(600)

    // MARK: - lifecycle

    /// Announce the source if the setting says so. Called at startup and from
    /// the settings change.
    func startNDIIfEnabled() {
        guard settings.ndi.enabled == true else { return }
        startNDIOutput()
    }

    func startNDIOutput() {
        guard mirrors.ndi == nil else { return }
        // Structural first. A build compiled without the SDK headers, or a
        // machine with no NDI runtime installed, cannot send at all — and that
        // is not something flicking the switch again can change, so the switch
        // is left exactly where the operator put it and the reason is what the
        // settings row shows. Checked only for the real sender: an injected one
        // is the test seam and is always available.
        if mirrors.ndiSenderFactory == nil, let reason = NDISender.unavailableReason {
            mirrors.ndiState = .unavailable(reason)
            return
        }
        do {
            let factory = mirrors.ndiSenderFactory ?? NDISender.make
            let sender = try factory(settings.ndiSourceNameEffective)
            mirrors.ndi = NDIVideoMirror(sender: sender)
            mirrors.ndiState = .sending
            wireDisplayMirrors()
        } catch {
            ndiFailed(error.localizedDescription)
        }
    }

    func stopNDIOutput() {
        mirrors.ndiRenameTask?.cancel()
        mirrors.ndiRenameTask = nil
        mirrors.ndi?.stop()
        mirrors.ndi = nil
        mirrors.ndiState = .off
        // Drop the display slot with it: with neither mirror left, the handler
        // goes back to nil and the display path stops calling anything at all.
        wireDisplayMirrors()
    }

    /// The sender could not be created though the SDK and the runtime are both
    /// there — almost always a source of that name already announced by another
    /// process (a second copy of TakeShot, or the same project on the next
    /// cart).
    ///
    /// The switch stays ON, which is where this parts company with
    /// `remoteFailed`. A port that will not bind is somebody else's process and
    /// there is nothing to type; a name clash is fixed by typing a different
    /// name in the field directly below the status — and that field, like the
    /// status, only exists while the switch is on. Turning it off would hide
    /// both the reason and the fix.
    func ndiFailed(_ message: String) {
        mirrors.ndi?.stop()
        mirrors.ndi = nil
        mirrors.ndiState = .failed(message)
        wireDisplayMirrors()
        lastError = L("ndi_failed", message)
    }

    // MARK: - settings changes (called from applySettingsChange)

    func applyNDIChange(from oldValue: CaptureSettings) {
        let wasOn = oldValue.ndi.enabled == true
        let isOn = settings.ndi.enabled == true
        if isOn, !wasOn {
            startNDIOutput()
        } else if !isOn, wasOn {
            stopNDIOutput()
        } else if isOn, oldValue.ndiSourceNameEffective
            != settings.ndiSourceNameEffective {
            scheduleNDIReannounce()
        }
    }

    /// A name change is a re-announce, not a reconfiguration: NDI publishes the
    /// name when the sender is created and there is no way to rename one. It is
    /// also the retry path after a name clash, which is why it does not care
    /// whether a mirror exists.
    ///
    /// The EFFECTIVE name, not the stored one, for the reason `applyRemoteChange`
    /// states about the port: the field writes the name it is showing, so the
    /// operator's first keystroke turns nil into the default without changing
    /// where anything points.
    private func scheduleNDIReannounce() {
        mirrors.ndiRenameTask?.cancel()
        mirrors.ndiRenameTask = Task { [weak self] in
            try? await Task.sleep(for: CaptureController.ndiRenameDebounce)
            guard !Task.isCancelled, let self,
                  self.settings.ndi.enabled == true else { return }
            self.mirrors.ndi?.stop()
            self.mirrors.ndi = nil
            self.startNDIOutput()
        }
    }
}
