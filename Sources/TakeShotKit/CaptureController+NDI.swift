import CaptureCore
import Foundation

/// The NDI output, from the controller's side: announcing the source, taking it
/// down, and what the operator is told when it cannot be had.
///
/// The frames come off the SAME display-mirror slot the hardware monitor, the
/// SRT stream and every WebRTC viewer ride (see `wireDisplayMirrors`), and NDI
/// names `LivePicture.decorated` out of it — the picture the operator and the director are
/// looking at, aids and chroma key included. That is the hardware monitor's case
/// and not the phone grid's: the grid gets the clean frame because it is a crew
/// monitoring surface where the operator's own tools would lie to it, and an NDI
/// feed exists to replace a cable to a director's monitor. Whoever watches it is
/// watching over the operator's shoulder, and should see the same picture.
///
/// **That reason is worth restating rather than inheriting, because the
/// argument that used to bind SRT and WebRTC never bound this one.** Those two
/// took the decorated frame partly because they shared one `LiveVideoEncoder`
/// and one H.264 session cannot compress two different pictures. That is
/// settled now — there is a session per distinct picture somebody is watching
/// (`CaptureController+LivePictures`), and a browser chooses. NDI was never
/// behind that encoder at all: it takes the display buffer, so it could have
/// taken the CLEAN frame for the cost of a second handler slot and no second
/// encode. It takes the decorated one anyway, on the merits — an NDI source is
/// a cable to a director's monitor, and a director watching a picture the
/// operator is not looking at is the failure this decision exists to avoid. It
/// is not offered a choice for the same reason SRT is not: there is a receiver
/// at the far end and no page, so nobody there could make one.
///
/// Nothing here exists while the switch is off: `mirrors.ndi` is nil, the display
/// slot holds no NDI consumer, and the SDK has not even been loaded — the
/// runtime dlopen happens on the first `unavailableReason` read, which is the
/// moment the operator asks for the feature.
///
/// **Picture only — and what is missing is now the LEG, not the tap.** NDI
/// carries audio and an iPad with no sound is half a monitor, which is the
/// sentence the SRT output used to carry at the top of
/// `CaptureController+SRT`. The obstacle both of them named was one and the
/// same: the pipeline's only stereo feed was `onMonitorAudio`, a single slot
/// owned by `AudioMonitor` (the room speakers) and gated on `monitorEnabled`,
/// so either feed hung off it would have made the sound on a director's iPad a
/// side effect of whether the operator has the cart's speakers up — and forcing
/// that switch on to get audio is precisely the bug `ControllerHarness` goes
/// out of its way to prevent. That half is built:
/// `CapturePipeline.addAudioTap` is one stereo mix per packet, taken once,
/// served to every outgoing transport, delivered whatever the monitor switch
/// says. SRT is the leg that came off it.
///
/// **What is left here is the NDI leg, and the reason it is left is that none
/// of it can be executed on this machine.** It is a planar-float conversion —
/// `NDIlib_send_send_audio_v3` takes de-interleaved 32-bit float where the tap
/// produces interleaved 16-bit integer — and a call into `CNDSender`, which is
/// a STUB in any build without the SDK headers, and there are no vendor drops
/// here or on CI at all. Written now it would be a conversion nothing calls and
/// a bridge call that compiles to nothing, shipped on the strength of having
/// been read rather than run.
///
/// What it costs when the headers land is small and known, which is the point
/// of stating the seam rather than guessing at the leg: `CapturePipeline+Audio`
/// does not change at all, `LiveAudioEncoder` is not involved (NDI takes PCM
/// and codes it itself), and the wiring is one more term in
/// `releaseIdleLiveAudio`'s `wanted` plus a consumer registered the way
/// `ensureLiveAudioEncoder` registers the first. The tap was the half both
/// outputs were waiting on, and it is the half that is here.
extension CaptureController {
    /// How long a name edit settles before the source is re-announced. The field
    /// writes on every keystroke and NDI has no way to rename a live sender, so
    /// each write would otherwise put another source in every receiver's list on
    /// the shoot — "MyFil", then "MyFilm". The same debounce, and for the same
    /// kind of reason, as the SRT link's rebuild and the volume slider's persist.
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
        // Structural first, exactly as the SRT switch does it. A build compiled
        // without the SDK headers, or a machine with no NDI runtime installed,
        // cannot send at all — and that is not something flicking the switch
        // again can change, so the switch is left exactly where the operator put
        // it and the reason is what the settings row shows. Checked only for the
        // real sender: an injected one is the test seam and is always available.
        if mirrors.ndiSenderFactory == nil, let reason = NDISender.unavailableReason {
            mirrors.ndiState = .unavailable(reason)
            return
        }
        do {
            let factory = mirrors.ndiSenderFactory ?? NDISender.make
            let sender = try factory(
                settings.ndi.sourceNameEffective(settings.naming))
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
        // Drop the display slot with it. Unlike `stopSRTOutput` there is no
        // shared session to release: this mirror owns its sender outright, so
        // nothing outlives the switch and `wireDisplayMirrors` is the whole of
        // the tidy-up. With no hardware output and nothing else watching, the
        // handler goes back to nil and the display path calls nothing at all.
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
        } else if isOn, oldValue.ndi.sourceNameEffective(oldValue.naming)
            != settings.ndi.sourceNameEffective(settings.naming) {
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
    /// where anything points. It is also why renaming the PROJECT re-announces —
    /// the default name is the project and the camera, so a source in a
    /// receiver's list follows what the shoot is called.
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
