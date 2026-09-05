import CaptureCore
import Foundation

/// The browser remote, from the controller's side: starting and stopping the
/// server, the status it pushes, and the four commands it accepts.
///
/// Every command lands on the method the on-screen button calls. There is no
/// second path to the recorder — a phone pressing REC and a finger pressing REC
/// go through `toggleManualRecord`, which is where the pre-roll, the naming and
/// the integrity alarms live. A remote that reimplemented any of that would
/// diverge from the app on the first bug fix.
extension CaptureController {
    /// How often the status goes out (4/s — smooth enough for a timecode
    /// readout at arm's length, and a fraction of the frame rate).
    static let remoteTick = Duration.milliseconds(250)
    /// Ticks between forced pushes. A status that has not changed still has to
    /// arrive, or a phone that missed one has no way to tell a still frame from
    /// a dead socket.
    static let remoteHeartbeatTicks = 20
    /// Ticks between free-space samples (every 5 s).
    static let remoteDiskTicks = 20

    // MARK: - lifecycle

    /// Start the server if the setting says so. Called at startup and from the
    /// settings change.
    func startRemoteIfEnabled() {
        guard settings.remote.enabled == true else { return }
        startRemoteServer()
    }

    /// Bring the server up.
    ///
    /// `overridePort` is the seam the tests use: they must never claim a fixed
    /// port on the machine running them, so they pass 0 and read back the
    /// ephemeral port the listener bound.
    func startRemoteServer(overridePort: Int? = nil) {
        guard remoteServer == nil else { return }
        // **Which server is speaking.** The handlers are closures with no
        // identity, and `remoteFailed` tore down whatever server was current
        // and flipped the switch off. A port change stops one server and starts
        // another; the old one's listener reports its failure on its own queue
        // a hop later — and that hop landed on the REPLACEMENT. The generation
        // is captured by the closures below and checked on arrival.
        remoteGeneration += 1
        let generation = remoteGeneration
        let pin = ensureRemotePIN()
        let server = RemoteServer(
            pin: pin, page: RemotePage.html(),
            scriptPage: RemotePage.scriptHTML(),
            livePage: RemotePage.liveHTML(),
            slatePage: RemotePage.slateHTML(),
            handlers: RemoteServer.Handlers(
                command: { [weak self] command in
                    // The server's queue must never touch the controller: every
                    // command hops here first, and runs exactly where the button
                    // handlers run.
                    Task { @MainActor in self?.perform(remote: command) }
                },
                ready: { [weak self] port in
                    Task { @MainActor in self?.remoteBoundPort = Int(port) }
                },
                failed: { [weak self] message in
                    Task { @MainActor in
                        self?.remoteFailed(message, generation: generation)
                    }
                },
                poster: { [weak self] takeID, reply in
                    // The thumbnails belong to the takes panel and live on the
                    // MainActor. The server's queue asks for one; it never
                    // reads controller state itself, here no more than anywhere
                    // else.
                    Task { @MainActor in
                        reply(self?.remoteTakePoster(id: takeID))
                    }
                },
                webrtcOffer: { [weak self] offer, picture, reply in
                    // The registry of viewers is controller state, so the
                    // decision hops here like a command does. What it starts
                    // does NOT run here: answering blocks on ICE gathering, and
                    // `answerWebRTCOffer` puts that on a queue of its own.
                    Task { @MainActor in
                        guard let self else {
                            reply(.unavailable(L("live_shutting_down")))
                            return
                        }
                        self.answerWebRTCOffer(offer, picture: picture,
                                               reply: reply)
                    }
                },
                webrtcPicture: { [weak self] viewer, picture, reply in
                    // Same hop, same reason: the registry and the encoder pool
                    // are controller state. This one does not block, so the
                    // verdict is known here and answered from here.
                    Task { @MainActor in
                        reply(self?.changeWebRTCPicture(viewer: viewer,
                                                        to: picture) ?? false)
                    }
                }))
        remoteServer = server
        server.start(port: UInt16(clamping: overridePort
                                  ?? settings.remote.portEffective))
        startRemoteStatusPump()
    }

    func stopRemoteServer() {
        remoteStatusTask?.cancel()
        remoteStatusTask = nil
        // The WebRTC viewers go with the server: there is
        // no other way to reach this app, so a peer connection left up would be
        // a picture going to a page that can no longer offer, rate or stop
        // anything.
        stopWebRTCViewers()
        remoteServer?.stop()
        remoteServer = nil
        remoteBoundPort = 0
    }

    /// The listener could not be had — almost always another process (or a
    /// second copy of TakeShot) already on the port. The toggle goes back off,
    /// because a switch left on over a server that is not listening is the
    /// version of this failure nobody can diagnose from the set.
    func remoteFailed(_ message: String, generation: Int? = nil) {
        // A failure from a server that has already been replaced is not news
        // about the one that is running.
        if let generation, generation != remoteGeneration { return }
        stopRemoteServer()
        if settings.remote.enabled == true { settings.remote.enabled = false }
        lastError = L("remote_failed", message)
    }

    /// The stored PIN, generated the first time the remote is switched on.
    @discardableResult
    func ensureRemotePIN() -> String {
        if let stored = settings.remote.pin, stored.count == 4,
           stored.allSatisfy(\.isNumber) {
            return stored
        }
        let fresh = RemotePIN.generate()
        settings.remote.pin = fresh
        return fresh
    }

    /// A new code, for when the old one has been read out to a unit that has
    /// wrapped. Sockets already open stay up until their next command.
    func regenerateRemotePIN() {
        let fresh = RemotePIN.generate()
        settings.remote.pin = fresh
    }

    /// The addresses to read out or scan for one page. Empty when the machine
    /// is on no usable network at all, which is worth showing as such.
    ///
    /// The path goes through `RemoteAddress.joined`, which is what keeps the
    /// host's trailing slash and the page's leading one from meeting.
    func remoteURLs(for link: RemoteLink = .remote) -> [String] {
        RemoteAddress.urls(port: remoteBoundPort > 0
                           ? remoteBoundPort : settings.remote.portEffective,
                           path: link.path)
    }

    // MARK: - settings changes (called from applySettingsChange)

    func applyRemoteChange(from oldValue: CaptureSettings) {
        let wasOn = oldValue.remote.enabled == true
        let isOn = settings.remote.enabled == true
        if isOn, !wasOn {
            startRemoteServer()
        } else if !isOn, wasOn {
            stopRemoteServer()
        } else if isOn, oldValue.remote.portEffective != settings.remote.portEffective {
            // A port change is a rebind, not a reconfiguration.
            //
            // The effective port, not the stored one: the port field writes the
            // number it is showing, so the operator's first keystroke turns nil
            // into 8765 without changing where the listener is. Comparing the
            // stored values called that a port change and tore down a working
            // listener to bind the port it was already on.
            stopRemoteServer()
            startRemoteServer()
        }
        if oldValue.remote.pin != settings.remote.pin, let pin = settings.remote.pin {
            remoteServer?.setPIN(pin)
        }
        if oldValue.theme.appLanguage != settings.theme.appLanguage {
            // The labels on the phone follow the app's language switch; the
            // pages are bytes behind the server's lock, so this needs no
            // restart.
            remoteServer?.setPage(RemotePage.html())
            remoteServer?.setScriptPage(RemotePage.scriptHTML())
            remoteServer?.setLivePage(RemotePage.liveHTML())
            remoteServer?.setSlatePage(RemotePage.slateHTML())
        }
    }
}
