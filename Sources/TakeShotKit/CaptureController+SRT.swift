import CaptureCore
import Foundation

/// The SRT output, from the controller's side: opening the link, taking it down,
/// and what the operator is told when it goes.
///
/// The frames come off the SAME display-mirror slot the hardware monitor rides
/// (see `wireDisplayMirrors`), and the picture SRT takes is named once, at
/// `CaptureController.srtPicture` — the decorated frame, aids and chroma key
/// included, because an SRT feed exists to replace a cable to a director's
/// monitor and whoever watches it is watching over the operator's shoulder.
/// Unlike a browser it is offered no choice, and the reason is written at that
/// constant.
///
/// Nothing here exists while the switch is off: `mirrors.srt` is nil, the display
/// slot holds no SRT consumer, and libsrt has not even been loaded — the runtime
/// `dlopen` happens on the first `SRTStream.unavailable` read, which is the moment the
/// operator asks for the feature.
///
/// **It carries sound now, and the tap it comes off is not the monitor's.**
/// The stereo feed is `CapturePipeline.addAudioTap` — one mix per packet, taken
/// once and served to every outgoing transport, delivered whatever
/// `monitorEnabled` says. That was the whole obstacle: the pipeline's only
/// stereo feed used to be `onMonitorAudio`, a single slot owned by
/// `AudioMonitor` and gated on the cart's speakers, so a feed hung off it would
/// have made a director's sound a side effect of whether the operator has the
/// speakers up. The channels are the ones in force for the FILE, folded to two
/// (see `CapturePipeline.stereoChannelIndices` for why that rule and not a
/// fixed 1-2).
///
/// From there the leg is this transport's own: `LiveAudioEncoder` compresses it
/// once, `MPEGTSMuxer` frames it in ADTS and puts it on a second PID against
/// the same 90 kHz clock the picture is stamped from, and the program map turns
/// on when the first access unit actually arrives rather than when an encoder
/// is constructed. There is no switch for it — a cable to a director's monitor
/// carries sound, and an operator cannot hear the far end to judge one.
///
/// **What only a real receiver can answer** is lip sync. Both streams are
/// stamped against one `LiveClock`, the picture at the moment a frame is
/// offered to the encoder and the sound at the moment its first packet is
/// accepted plus an exact 1920 ticks per access unit — so the arithmetic cannot
/// drift, and the OFFSET between the two paths' latencies has never been
/// measured against a decoder. It is a constant, not a drift, and a receiver is
/// what would show its size.
///
/// **The NDI leg is still open, and the shared half is now built.** Both feeds
/// wanted one independent stereo tap and only the leg after it differs — AAC
/// and a second PID here, planar float and `NDIlib_send_send_audio_v3` there.
/// The tap is the half that is done; see `CaptureController+NDI` for why that
/// leg is not, and `CaptureController+LiveAudio` for the one line that widens
/// when it is.
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
           let reason = SRTStream.unavailable {
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
        let mirror = SRTMirror(
            endpoint: endpoint,
            // The session for the picture this link carries. A browser already
            // watching the same one hands this link a warm encoder; the switch
            // being thrown first builds one that a viewer joins later.
            encoder: ensureLiveEncoder(for: Self.srtPicture),
            // …and the one AAC session, which also registers the pipeline's
            // audio tap. Built here rather than in `wireDisplayMirrors`
            // because sound does not ride the display slot: it comes off the
            // capture queue's audio path, which no picture is on.
            audioEncoder: ensureLiveAudioEncoder(),
            factory: factory,
            onEvent: { [weak self] event in
                // The mirror's queue must never touch the controller: every event
                // hops here first, and lands where the button handlers run.
                Task { @MainActor in self?.applySRTEvent(event) }
            },
            onMeasurement: { [weak self] buffer, roundTrip in
                Task { @MainActor in
                    guard let self, self.mirrors.srt != nil else { return }
                    self.mirrors.srtLatencyMs = buffer
                    self.mirrors.srtRoundTripMs = roundTrip
                }
            })
        mirrors.srt = mirror
        mirrors.srtEndpoint = endpoint
        // Whoever turned it on — the footer or the Settings row — it is no
        // longer paused, so the footer's button goes back to meaning "stop".
        mirrors.pausedStreams.srt = false
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
        mirrors.srtLatencyMs = nil
        mirrors.srtRoundTripMs = nil
        // Drop the display slot with it — but only if nothing else is watching.
        // The session outlives this switch when a browser is on the same
        // picture, and `releaseIdleLivePictures` is the one place that decides;
        // it re-wires every slot either way.
        releaseIdleLivePictures()
        // The sound is a separate question and gets a separate answer: no
        // browser takes it today, so the SRT switch really is the last one out
        // — but the decision lives in one place so that stops being true by one
        // line rather than by this call being wrong.
        releaseIdleLiveAudio()
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
    func applySRTEvent(_ event: SRTMirror.Event) {
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
        case .passphraseTooLong:
            return L("srt_passphrase_long", SRTSettings.passphraseMaximum)
        }
    }

    // MARK: - settings changes (called from applySettingsChange)

    func applySRTChange(from oldValue: CaptureSettings) {
        // The bitrate is the ONE field in this group that no longer needs a new
        // link, and it is checked before the switch rather than inside it: the
        // sessions outlive this switch, so an operator can be turning it down
        // while the SRT switch is off and a browser is the only thing watching.
        // It moves on the running sessions rather than rebuilding them — see
        // `LiveVideoEncoder.setBitsPerSecond`.
        if oldValue.srt.bitsPerSecondEffective
            != settings.srt.bitsPerSecondEffective {
            // Every session, not one: the dial is the only bitrate the app has
            // and each picture being watched is paying it (see
            // `CaptureController+LivePictures`).
            for encoder in mirrors.liveEncoders.values {
                encoder.setBitsPerSecond(settings.srt.bitsPerSecondEffective)
            }
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
