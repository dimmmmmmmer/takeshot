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
        guard settings.remoteEnabled == true else { return }
        startRemoteServer()
    }

    /// Bring the server up.
    ///
    /// `overridePort` is the seam the tests use: they must never claim a fixed
    /// port on the machine running them, so they pass 0 and read back the
    /// ephemeral port the listener bound.
    func startRemoteServer(overridePort: Int? = nil) {
        guard remoteServer == nil else { return }
        let pin = ensureRemotePIN()
        let server = RemoteServer(
            pin: pin, page: RemotePage.html(),
            scriptPage: RemotePage.scriptHTML(),
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
                    Task { @MainActor in self?.remoteFailed(message) }
                },
                poster: { [weak self] reply in
                    // The thumbnails belong to the takes panel and live on the
                    // MainActor. The server's queue asks for one; it never
                    // reads controller state itself, here no more than anywhere
                    // else.
                    Task { @MainActor in reply(self?.remoteTakePoster()) }
                }))
        remoteServer = server
        server.start(port: UInt16(clamping: overridePort
                                  ?? settings.remotePortEffective))
        startRemoteStatusPump()
    }

    func stopRemoteServer() {
        remoteStatusTask?.cancel()
        remoteStatusTask = nil
        remoteServer?.stop()
        remoteServer = nil
        remoteBoundPort = 0
    }

    /// The listener could not be had — almost always another process (or a
    /// second copy of TakeShot) already on the port. The toggle goes back off,
    /// because a switch left on over a server that is not listening is the
    /// version of this failure nobody can diagnose from the set.
    func remoteFailed(_ message: String) {
        stopRemoteServer()
        if settings.remoteEnabled == true { settings.remoteEnabled = false }
        lastError = L("remote_failed", message)
    }

    /// The stored PIN, generated the first time the remote is switched on.
    @discardableResult
    func ensureRemotePIN() -> String {
        if let stored = settings.remotePIN, stored.count == 4,
           stored.allSatisfy(\.isNumber) {
            return stored
        }
        let fresh = RemotePIN.generate()
        settings.remotePIN = fresh
        return fresh
    }

    /// A new code, for when the old one has been read out to a unit that has
    /// wrapped. Sockets already open stay up until their next command.
    func regenerateRemotePIN() {
        let fresh = RemotePIN.generate()
        settings.remotePIN = fresh
    }

    /// The addresses to read out or scan. Empty when the machine is on no
    /// network at all, which is worth showing as such.
    var remoteURLs: [String] {
        RemoteAddress.urls(port: remoteBoundPort > 0
                           ? remoteBoundPort : settings.remotePortEffective)
    }

    // MARK: - settings changes (called from applySettingsChange)

    func applyRemoteChange(from oldValue: CaptureSettings) {
        let wasOn = oldValue.remoteEnabled == true
        let isOn = settings.remoteEnabled == true
        if isOn, !wasOn {
            startRemoteServer()
        } else if !isOn, wasOn {
            stopRemoteServer()
        } else if isOn, oldValue.remotePortEffective != settings.remotePortEffective {
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
        if oldValue.remotePIN != settings.remotePIN, let pin = settings.remotePIN {
            remoteServer?.setPIN(pin)
        }
        if oldValue.appLanguage != settings.appLanguage {
            // The labels on the phone follow the app's language switch; the
            // pages are bytes behind the server's lock, so this needs no
            // restart.
            remoteServer?.setPage(RemotePage.html())
            remoteServer?.setScriptPage(RemotePage.scriptHTML())
        }
    }
}
