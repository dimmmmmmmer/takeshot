import CaptureCore
import Foundation

/// The SRT output, from the controller's side: opening the link, taking it down,
/// and what the operator is told when it goes.
///
/// The frames come off the SAME display-mirror slot the hardware monitor rides
/// (see `wireDisplayMirrors`), so SRT carries the DECORATED frame — the picture
/// the operator and the director are looking at, aids and chroma key included.
/// That is the hardware monitor's case and not the phone grid's: the grid gets
/// the clean frame because it is a crew monitoring surface where the operator's
/// own tools would lie to it, and an SRT feed exists to replace a cable to a
/// director's monitor. Whoever watches it is watching over the operator's
/// shoulder, and should see the same picture.
///
/// Nothing here exists while the switch is off: `mirrors.srt` is nil, the display
/// slot holds no SRT consumer, and libsrt has not even been loaded — the runtime
/// `dlopen` happens on the first `unavailableReason` read, which is the moment the
/// operator asks for the feature.
///
/// **Picture only, on purpose, and here is the door.** MPEG-TS carries audio
/// perfectly well and SRT does not care, but the only stereo feed the pipeline
/// produces is `onMonitorAudio`, and it is wrong for this twice over. It is a
/// single slot already owned by `AudioMonitor` (the room speakers), and it is
/// gated on `monitorEnabled` — so an SRT feed hung off it would make the sound on
/// a director's laptop a side effect of whether the operator has the cart's
/// speakers up, and forcing that switch on to get audio is precisely the bug
/// `ControllerHarness` goes out of its way to prevent. Sending sound therefore
/// needs a SECOND tap in `CapturePipeline+Audio`, independent of the monitor and
/// of its channel mask, plus an AAC encoder and a second elementary stream in
/// `MPEGTSMuxer` with its own PID and its own PES timing against the same 90 kHz
/// clock. That is a path with a timing contract of its own and none of it can be
/// checked without a real receiver, so it is not being guessed at here. The
/// picture is the half that replaces a cable.
extension CaptureController {
    /// How long a settings edit settles before the link is rebuilt.
    ///
    /// The address field writes on every keystroke and there is no way to
    /// re-point a live SRT socket, so each write would otherwise open and close a
    /// link per character — "10.", "10.0", "10.0." — each one a handshake attempt
    /// at an address that does not exist yet. The same debounce, for the same kind
    /// of reason, as the volume slider's persist.
    static let srtRestartDebounce = Duration.milliseconds(600)

    // MARK: - lifecycle

    /// Open the link if the setting says so. Called at startup and from the
    /// settings change.
    func startSRTIfEnabled() {
        guard settings.srt.enabled == true else { return }
        startSRTOutput()
    }

    func startSRTOutput() {
        guard mirrors.srt == nil else { return }
        // Structural first. A build compiled without the libsrt headers, or a
        // machine with none installed, cannot send at all — and that is not
        // something flicking the switch again can change, so the switch is left
        // exactly where the operator put it and the reason is what the settings
        // row shows. Checked only for the real stream: an injected one is the test
        // seam and is always available.
        if mirrors.srtStreamFactory == nil,
           let reason = SRTStream.unavailableReason {
            mirrors.srtState = .unavailable(reason)
            return
        }
        // Then the two things the operator can get wrong, which are caught HERE
        // rather than at the socket so they can be said in their own language.
        if let problem = settings.srt.configurationProblem {
            mirrors.srtState = .failed(Self.srtProblem(problem))
            return
        }
        guard let endpoint = settings.srt.endpoint else { return }
        openSRTLink(to: endpoint)
    }

    private func openSRTLink(to endpoint: SRTEndpoint) {
        let factory: @Sendable (SRTEndpoint) throws -> SRTStreamSending =
            mirrors.srtStreamFactory ?? { SRTStream.make($0) }
        let mirror = SRTVideoMirror(
            endpoint: endpoint,
            // The session every live consumer shares. A WebRTC viewer already
            // watching hands this link a warm encoder; the switch being thrown
            // first builds one that a viewer joins later.
            encoder: ensureLiveEncoder(),
            factory: factory,
            onEvent: { [weak self] event in
                // The mirror's queue must never touch the controller: every event
                // hops here first, and lands where the button handlers run.
                Task { @MainActor in self?.applySRTEvent(event) }
            })
        mirrors.srt = mirror
        mirrors.srtEndpoint = endpoint
        // `starting` and not `sending`: the connect has not happened yet, and it
        // cannot happen here — it blocks, and this is the MainActor.
        mirrors.srtState = .starting
        wireDisplayMirrors()
        mirror.start()
    }

    func stopSRTOutput() {
        mirrors.srtRestartTask?.cancel()
        mirrors.srtRestartTask = nil
        mirrors.srt?.stop()
        mirrors.srt = nil
        mirrors.srtEndpoint = nil
        mirrors.srtState = .off
        // Drop the display slot with it — but only if nothing else is watching.
        // The shared encoder outlives this switch when a browser is on it, and
        // `releaseLiveEncoderIfIdle` is the one place that decides; it re-wires
        // the display slot either way.
        releaseLiveEncoderIfIdle()
        wireDisplayMirrors()
    }

    /// What the mirror says about the link, turned into what Settings shows.
    ///
    /// **A lost link gets no toast, and that is the decision in this function.**
    /// On a venue network the receiver is closed half the day and the Wi-Fi comes
    /// and goes; a toast per drop would put a banner over the picture during a
    /// take, repeatedly, for a condition that resolves itself. So a loss is a
    /// status row and a reconnect, and the only thing that toasts is `refused` —
    /// a configuration the operator has to go and change, which is exactly the
    /// case where nothing will improve until somebody is told.
    func applySRTEvent(_ event: SRTVideoMirror.Event) {
        // A late event from a mirror that has already been stopped: the switch is
        // off and the row says so, and it must not be talked back out of that.
        guard mirrors.srt != nil else { return }
        switch event {
        case .opened:
            mirrors.srtState = .sending
        case .waiting:
            mirrors.srtState = .starting
        case .lost(let reason):
            mirrors.srtState = .reconnecting(reason)
        case .refused(let reason):
            mirrors.srtState = .failed(reason)
            lastError = L("srt_failed", reason)
        case .unavailable(let reason):
            mirrors.srtState = .unavailable(reason)
        }
    }

    /// The two configuration mistakes, in words. English lives in the tables like
    /// every other UI string — unlike the bridge's reasons, which name a shell
    /// command and a directory and are worse translated than left alone.
    static func srtProblem(_ problem: SRTSettings.Problem) -> String {
        switch problem {
        case .addressMissing:
            return L("srt_needs_address")
        case .passphraseTooShort:
            return L("srt_passphrase_short", SRTSettings.passphraseMinimum)
        }
    }

    // MARK: - settings changes (called from applySettingsChange)

    func applySRTChange(from oldValue: CaptureSettings) {
        // The bitrate is the ONE field in this group that no longer needs a new
        // link, and it is checked before the switch rather than inside it: the
        // encoder is shared now, so an operator can be turning it down while
        // the SRT switch is off and a browser is the only thing watching. It
        // moves on the running session rather than rebuilding one — see
        // `LiveVideoEncoder.setBitsPerSecond`.
        if oldValue.srt.bitsPerSecondEffective
            != settings.srt.bitsPerSecondEffective {
            mirrors.liveEncoder?.setBitsPerSecond(
                settings.srt.bitsPerSecondEffective)
        }
        let wasOn = oldValue.srt.enabled == true
        let isOn = settings.srt.enabled == true
        if isOn, !wasOn {
            startSRTOutput()
        } else if !isOn, wasOn {
            stopSRTOutput()
        } else if isOn, oldValue.srt != settings.srt {
            scheduleSRTRestart()
        }
    }

    /// Any change to the group is a new link.
    ///
    /// Compared as a WHOLE GROUP rather than field by field, and that is the
    /// honest reading: there is nothing in it a live link can be re-pointed at.
    /// The role, the address, the port, the latency and the passphrase are all
    /// fixed at the handshake, and the bitrate is fixed when the encoder is
    /// built. Comparing the group is also what keeps this correct when a field is
    /// added to it.
    ///
    /// It is the retry path after a `refused`, too, which is why it does not care
    /// whether a mirror exists: the fix for "no address" is typing one, and a
    /// keystroke is what has to set the next attempt going.
    private func scheduleSRTRestart() {
        mirrors.srtRestartTask?.cancel()
        mirrors.srtRestartTask = Task { [weak self] in
            try? await Task.sleep(for: CaptureController.srtRestartDebounce)
            guard !Task.isCancelled, let self,
                  self.settings.srt.enabled == true else { return }
            self.mirrors.srt?.stop()
            self.mirrors.srt = nil
            self.startSRTOutput()
        }
    }
}
