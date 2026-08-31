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
/// runtime dlopen happens on the first `NDISender.unavailable` read, which is the
/// moment the operator asks for the feature.
///
/// **Picture and sound, off one tap.** NDI carries audio and an iPad with no
/// sound is half a monitor. Both this output and SRT used to be picture only
/// for one shared reason: the pipeline's only stereo feed was `onMonitorAudio`,
/// a single slot owned by `AudioMonitor` (the room speakers) and gated on
/// `monitorEnabled`, so either feed hung off it would have made the sound on a
/// director's iPad a side effect of whether the operator has the cart's
/// speakers up — and forcing that switch on to get audio is precisely the bug
/// `ControllerHarness` goes out of its way to prevent.
///
/// `CapturePipeline.addAudioTap` is that feed without the gate: ONE stereo mix
/// per packet, built after `recordAudio` so nothing it does can reach the file,
/// handed to the speakers and to every registered consumer alike. This file
/// registers one of those consumers and only the LEG after it is NDI's own:
/// `NDIAudioMirror` converts the tap's interleaved 16-bit packet to the
/// de-interleaved 32-bit float `NDIlib_send_send_audio_v3` takes, on a queue of
/// its own. There is no second tap, no second mix and no second channel rule —
/// the channels are `stereoChannelIndices`, the same expression the record path
/// reads, so what goes out is always a prefix of what is being written.
///
/// **`LiveAudioEncoder` is not involved, and that is not an omission.** The AAC
/// session exists for the transport stream, which needs an elementary stream;
/// NDI takes PCM and codes it itself, exactly as it takes frames rather than
/// H.264. So the NDI switch changes nothing in `CaptureController+LiveAudio`
/// and nothing in `CapturePipeline+Audio` — an NDI source with no SRT link
/// builds no AAC encoder at all, which is what
/// `theNDILegBuildsNoAACEncoder` pins.
///
/// **Two queues for one source, which is a claim about failure rather than
/// about speed.** `NDIVideoMirror` sends on `com.takeshot.ndi` and
/// `NDIAudioMirror` on `com.takeshot.ndi-audio`, against the same `CNDSender`.
/// Both sends are synchronous and either can park for as long as its receiver
/// makes it, so one queue would mean a stalled picture holding up its own sound
/// — the same coupling `aParkedNDISendDoesNotStallTheSRTLink` rules out between
/// the two OUTPUTS, now ruled out inside this one. What is serialized between
/// them is the sender's lifetime and nothing else; see `CNDSender.stop`.
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
        if mirrors.ndiSenderFactory == nil, let reason = NDISender.unavailable {
            mirrors.ndiState = .unavailable(reason)
            return
        }
        do {
            let factory = mirrors.ndiSenderFactory ?? NDISender.make
            let sender = try factory(
                settings.ndi.sourceNameEffective(settings.naming))
            mirrors.ndi = NDIVideoMirror(
                sender: sender,
                onRefused: { [weak self] count in
                    // The mirror's queue must never touch the controller.
                    Task { @MainActor in self?.noteNDIRefusing(count) }
                })
            // Whoever turned it on — the footer or the Settings row — it is no
            // longer paused, so the footer's button goes back to meaning "stop".
            mirrors.pausedStreams.ndi = false
            startNDIAudio(on: sender)
            // ANNOUNCED, not sending. The source has just been created; nobody
            // can have opened it yet, and saying "sending" here is what made
            // the state mean "the switch is on" — see `NDIOutputState`.
            mirrors.ndiState = .announced
            startNDILinkPoll()
            wireDisplayMirrors()
        } catch {
            ndiFailed(error.localizedDescription)
        }
    }

    /// Poll the link for as long as there is a sender.
    ///
    /// Its own task rather than a line in the remote's status pump: that pump
    /// only runs when the web remote is switched ON, and whether a director's
    /// laptop is taking the NDI picture has nothing to do with whether anybody
    /// opened the phone page. Tied to the sender's life instead, which is
    /// exactly the span over which the question means anything.
    ///
    /// A second apart. NDI has no connection event, so this is the cadence at
    /// which a receiver appearing becomes visible — fast enough for an operator
    /// to see somebody join, slow enough to be free.
    private func startNDILinkPoll() {
        mirrors.ndiLinkTask?.cancel()
        mirrors.ndiLinkTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refreshNDILink()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Ask the sender how many receivers have the source open, and move the
    /// state between `announced` and `sending` on the answer.
    ///
    /// A POLL because NDI offers no event: there is no "somebody connected"
    /// callback in the SDK, so the app asks on the tick it already pushes its
    /// remote status on. A runtime that cannot say answers -1, and the state
    /// then stays where an older build would have left it.
    ///
    /// Only while a sender exists. Nothing else moves this state, so a failure
    /// or the switch going off is not overwritten by a poll that ran after it.
    func refreshNDILink() {
        guard let sender = mirrors.ndi?.sender else { return }
        switch mirrors.ndiState {
        case .announced, .sending:
            let count = sender.connectedReceivers
            guard count >= 0 else {
                // The runtime cannot answer. Say what an older build said —
                // the source is up — rather than claiming nobody is watching.
                mirrors.ndiState = .sending
                return
            }
            let wanted: NDIOutputState = count > 0 ? .sending : .announced
            if mirrors.ndiState != wanted { mirrors.ndiState = wanted }
        case .off, .failed, .unavailable:
            break
        }
    }

    /// Put the sound leg on the same sender and register it on the pipeline's
    /// stereo tap.
    ///
    /// The tap closure holds the mirror WEAKLY, for the reason
    /// `ensureLiveAudioEncoder`'s does: the closure is owned by the PIPELINE and
    /// runs on the capture queue, and it must not be what keeps a mirror the
    /// controller has already dropped alive. `stopNDIAudio` removes it anyway —
    /// this is the belt on the braces, and it is the half that survives a path
    /// that forgets to.
    private func startNDIAudio(on sender: NDISending) {
        // Asked ONCE, here, rather than per packet: it is a property of the
        // loaded runtime and cannot change while one is loaded. A runtime that
        // cannot carry sound still gets its mirror and its tap — the packets
        // are refused at the bridge and the picture is unaffected — but the
        // operator is told, because a silent feed the app knew about in advance
        // is worse than one it could not predict.
        mirrors.ndiCarriesAudio = NDISender.isAudioAvailable
        let mirror = NDIAudioMirror(sender: sender)
        mirrors.ndiAudio = mirror
        pipeline.addAudioTap(mirror) { [weak mirror] packet in
            mirror?.offer(packet)
        }
    }

    /// …and take it off, tap first.
    ///
    /// The ORDER is the point: the tap is removed while the mirror still
    /// exists, so the capture queue stops being handed packets before anything
    /// is torn down. `stop()` then makes the ones already in flight inert.
    private func stopNDIAudio() {
        guard let mirror = mirrors.ndiAudio else { return }
        pipeline.removeAudioTap(mirror)
        mirror.stop()
        mirrors.ndiAudio = nil
        mirrors.ndiCarriesAudio = nil
    }

    /// The source is announced, the receiver is still connected, and the
    /// bridge has been refusing frames for long enough that what the receiver
    /// is looking at is a still.
    ///
    /// Reported into the NDI row rather than the alarm banner: no footage is at
    /// risk — the recorder is not in this path at all — and the picture the
    /// director is watching having stopped is exactly what the stream lamp is
    /// for. `StreamLink` reads `.failed` as trouble, so the lamp goes amber
    /// with a triangle instead of staying green.
    func noteNDIRefusing(_ count: Int) {
        guard mirrors.ndi != nil else { return }
        mirrors.ndiState = .failed(L("ndi_refusing", count))
    }

    /// Take every live output down at once.
    ///
    /// What the footer's indicator presses. One verb rather than two switches,
    /// because the question an operator asks mid-shoot is "stop sending", not
    /// "which of the two transports did I want to stop" — and the settings
    /// switches are still there for the other case.
    ///
    /// It writes the SETTINGS rather than calling the two stop methods, so the
    /// switches move with it: a stream stopped from the footer must not come
    /// back the next time something re-applies the settings.
    func stopAllStreams() {
        var paused = PausedStreams()
        if settings.ndi.enabled == true {
            paused.ndi = true
            settings.ndi.enabled = false
        }
        if settings.srt.enabled == true {
            paused.srt = true
            settings.srt.enabled = false
        }
        // Only when something was actually stopped: a second press on an
        // already-stopped footer must not erase what the first one remembered.
        if paused.any { mirrors.pausedStreams = paused }
    }

    /// Switch back on exactly what `stopAllStreams` switched off.
    ///
    /// Exactly what, and not "everything that is configured": an operator who
    /// turned NDI off in Settings before the shoot has not asked for it back,
    /// and a footer button that decided otherwise would put a picture on the
    /// set network they had deliberately taken off it.
    func resumeStreams() {
        let paused = mirrors.pausedStreams
        guard paused.any else { return }
        mirrors.pausedStreams = PausedStreams()
        if paused.ndi { settings.ndi.enabled = true }
        if paused.srt { settings.srt.enabled = true }
    }

    func stopNDIOutput() {
        mirrors.ndiLinkTask?.cancel()
        mirrors.ndiLinkTask = nil
        mirrors.ndiRenameTask?.cancel()
        mirrors.ndiRenameTask = nil
        stopNDIAudio()
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
        // The sound goes with the picture on every path that drops the mirror,
        // and it goes FIRST for `stopNDIAudio`'s reason. A leg left registered
        // on the pipeline over a source that no longer exists is a per-packet
        // conversion for nobody, on the queue that owns the file.
        stopNDIAudio()
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
            self.stopNDIAudio()
            self.mirrors.ndi?.stop()
            self.mirrors.ndi = nil
            self.startNDIOutput()
        }
    }
}
