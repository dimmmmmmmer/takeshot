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
    ///
    /// **Every tick carries one, whether or not anything changed**, and that
    /// is load-bearing rather than lazy: the slate page treats a gap longer
    /// than `RemotePage.slateHoldMilliseconds` as doubt about the number and
    /// refuses to clap. There used to be a `remoteHeartbeatTicks` that let an
    /// unchanged status wait five seconds — see the pump in `+RemoteStatus`
    /// for what that did to a camera sitting in standby.
    static let remoteTick = Duration.milliseconds(250)
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
            pin: pin, pagePINs: remotePagePINs, page: RemotePage.html(),
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
    ///
    /// All FOUR are ensured together — the operator's and the three pages' —
    /// because a page whose code is nil would otherwise fall back to nothing
    /// and be openable by the master alone, which is not what having its own
    /// code means.
    @discardableResult
    func ensureRemotePIN() -> String {
        let operatorPIN = Self.usablePIN(settings.remote.pin)
            ?? RemotePIN.generate()
        settings.remote.pin = operatorPIN
        settings.remote.slatePIN = Self.usablePIN(settings.remote.slatePIN)
            ?? RemotePIN.generate()
        settings.remote.livePIN = Self.usablePIN(settings.remote.livePIN)
            ?? RemotePIN.generate()
        settings.remote.scriptPIN = Self.usablePIN(settings.remote.scriptPIN)
            ?? RemotePIN.generate()
        return operatorPIN
    }

    /// The code that opens one page, as Settings shows it.
    func remotePIN(for link: RemoteLink) -> String? {
        switch link {
        case .remote: return settings.remote.pin
        case .slate: return settings.remote.slatePIN
        case .live: return settings.remote.livePIN
        case .script: return settings.remote.scriptPIN
        }
    }

    /// The three auxiliary pages' codes, keyed by `RemoteLink` raw value.
    ///
    /// The operator's is not in here: it is the master and the server holds it
    /// separately (`RemoteServer.currentPIN`), which is what keeps "this code
    /// opens everything" one statement rather than four entries.
    var remotePagePINs: [String: String] {
        var pins: [String: String] = [:]
        pins[RemoteLink.slate.rawValue] = settings.remote.slatePIN
        pins[RemoteLink.live.rawValue] = settings.remote.livePIN
        pins[RemoteLink.script.rawValue] = settings.remote.scriptPIN
        return pins.compactMapValues { $0 }
    }

    /// A stored code that is still a code: the right length, all digits.
    /// Anything else is a hand-edited blob and gets a fresh one.
    static func usablePIN(_ stored: String?) -> String? {
        guard let stored, stored.count == RemoteSettings.pinLength,
              stored.allSatisfy(\.isNumber) else { return nil }
        return stored
    }

    /// A new code, for when the old one has been read out to a unit that has
    /// wrapped. **The sockets that were holding it are turned away** — see
    /// `RemoteServer.setPIN` and `setPagePINs` for why refusing their next
    /// command is not enough (the slate and the live page send none).
    ///
    /// One page at a time: rotating the slate's code because a runner walked
    /// off with the phone must not lock out the script supervisor.
    func regenerateRemotePIN(for link: RemoteLink = .remote) {
        store(RemotePIN.generate(), for: link)
    }

    /// A code the operator TYPED, for a unit that already has one written on a
    /// piece of tape (owner: "пин кстати все еще руками не могу сделать для
    /// ремоутов").
    ///
    /// Vetted by `usablePIN` — the rule that already decides whether a STORED
    /// code is still a code — so a typed one and a generated one are the same
    /// kind of thing, and nothing downstream can tell them apart. Refused
    /// rather than repaired: a field that padded "12" into "1200" would hand
    /// out a code the operator did not choose and would read out the wrong one
    /// to the set.
    ///
    /// **Nothing here refuses 1234 or 0000, on purpose.** This is a code for a
    /// page on a set network, written on tape and read out across a cart; the
    /// thing that stops guessing is the tarpit (`RemotePINTarpit`), which is
    /// deaf to how memorable the number is. A settings field that argued with
    /// an operator about their own code would be answered with a Post-it.
    ///
    /// Answers whether it was taken, so the field can snap back to the stored
    /// code rather than showing an edit that was not kept.
    @discardableResult
    func setRemotePIN(_ typed: String, for link: RemoteLink = .remote) -> Bool {
        guard let pin = Self.usablePIN(typed) else { return false }
        store(pin, for: link)
        return true
    }

    /// Where a code lands. One switch, so a generated code and a typed one
    /// cannot come to be stored in different places.
    private func store(_ pin: String, for link: RemoteLink) {
        switch link {
        case .remote: settings.remote.pin = pin
        case .slate: settings.remote.slatePIN = pin
        case .live: settings.remote.livePIN = pin
        case .script: settings.remote.scriptPIN = pin
        }
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
        // **Every settings change, not only a language switch.** The page
        // codes used to be handed over inside the branch below, so rotating
        // the slate's code wrote the setting and changed nothing on a running
        // server — the phone went on being let in with the retired one until
        // the app was restarted. The server does the diff and retires only
        // what moved, so handing it the whole set every time costs a lock and
        // cannot forget a field.
        remoteServer?.setPagePINs(remotePagePINs)
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
