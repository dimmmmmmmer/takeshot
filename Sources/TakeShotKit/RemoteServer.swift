import Foundation
import Network
import os

/// The embedded server the phones on the set network talk to: one page, one
/// socket, one port.
///
/// Everything mutable lives on `queue`, a serial queue of its own — the capture
/// queue owns per-frame work and must never wait on a socket, and the MainActor
/// must never wait on one either. The two values that cross in from outside
/// (the PIN and the rendered page) sit behind a lock rather than being closure
/// properties: a closure read on one thread while another writes it hands the
/// caller a function pointer paired with the wrong context (see
/// docs/ARCHITECTURE.md).
final class RemoteServer: @unchecked Sendable {
    /// What the server reports back. Handed in at construction and never
    /// replaced, for the same reason.
    struct Handlers: Sendable {
        /// A command that passed the PIN check, on the server's queue.
        var command: @Sendable (RemoteCommand) -> Void
        /// The listener is up on this port (the bound one — the caller may
        /// have asked for 0).
        var ready: @Sendable (UInt16) -> Void
        /// The listener died. A port already in use arrives here.
        var failed: @Sendable (String) -> Void
        /// One take's poster, as JPEG bytes; nil while there is none to hand
        /// over yet. The take is named by id — an empty string means the
        /// freshest one, which is what the operator page's card is about,
        /// while the script page asks for a specific row.
        ///
        /// Asked for on the server's queue and answered from wherever the app
        /// keeps the image — the MainActor — so the reply is a closure the app
        /// calls back rather than a return value. The default answers "none",
        /// which is what a server driven without a controller has.
        var poster: @Sendable (String, @escaping @Sendable (Data?) -> Void) -> Void
            = { _, reply in reply(nil) }
        /// Somebody started (true) or the last somebody stopped (false)
        /// watching the multiview stream. The app answers by building or
        /// tearing down the encoder, so an idle set encodes nothing. Called
        /// on the server's queue, only on a change. The default ignores it,
        /// which is what a server driven without a controller wants.
        var multiviewDemand: @Sendable (Bool) -> Void = { _ in }
    }

    /// The values the app pushes in while the server runs: the PIN and the
    /// localized pages. All change without a restart (the operator switches
    /// language, or regenerates the code).
    private struct Shared {
        var pin: String
        var page: Data
        var scriptPage: Data
        var camerasPage: Data
    }

    /// A handful of phones is the whole use case. The cap is what stops a
    /// script pointed at the port from opening sockets until the app that is
    /// recording runs out of file descriptors.
    static let maximumClients = 8

    /// Binds retried when the port is reported already taken, before the failure
    /// is surfaced to the operator.
    ///
    /// A rebind on the same port races the previous listener's cancel, which is
    /// asynchronous: `stop()` returns long before the socket is released. The
    /// operator meets that race by editing the port field or by switching the
    /// remote off and straight back on, and without a retry the answer is
    /// "Address already in use" and a switch that turned itself off — blamed on
    /// whatever else is on the machine. A port another process really owns is
    /// still reported, one short retry window later.
    static let bindRetries = 4
    static let bindRetryDelay = DispatchTimeInterval.milliseconds(120)

    static let log = Logger(subsystem: "com.takeshot.app", category: "remote")

    /// Read by `RemoteServer+Listener` as well as here, so module-internal
    /// rather than private — never wider than the module.
    let handlers: Handlers
    let queue = DispatchQueue(label: "com.takeshot.remote")
    private let shared: OSAllocatedUnfairLock<Shared>

    // MARK: - queue-confined state

    var listener: NWListener?
    var clients: [ObjectIdentifier: RemoteClient] = [:]
    /// The port `start` was asked for, kept for a retried bind.
    var requestedPort: UInt16 = 0
    var bindAttempts = 0
    /// `stop()` has been called. A retry scheduled before it must not bring a
    /// listener back up behind the operator's switch.
    var isStopped = false
    /// The last status pushed, replayed to a client the moment it authenticates
    /// so a phone picked up mid-take shows the take rather than a blank readout.
    private var lastStatus: String?
    /// The last take log pushed, replayed on authentication for the same
    /// reason: a script page opened mid-shift shows the day so far, not an
    /// empty table waiting for the next take to land.
    private var lastTakeLog: String?
    /// The one piece of state that has to be the SERVER's rather than a
    /// connection's, because a reconnect is what defeats every per-connection
    /// count. See `RemotePINTarpit`.
    private var tarpit = RemotePINTarpit()
    /// What `handlers.multiviewDemand` was last told, so the app hears about
    /// edges only — every subscribe, unsubscribe and disconnect recounts, and
    /// most recounts change nothing.
    private var multiviewDemand = false

    init(pin: String, page: Data, scriptPage: Data = Data(),
         camerasPage: Data = Data(), handlers: Handlers) {
        self.handlers = handlers
        self.shared = OSAllocatedUnfairLock(
            initialState: Shared(pin: pin, page: page, scriptPage: scriptPage,
                                 camerasPage: camerasPage))
    }

    /// Start listening. `port` 0 binds an ephemeral one and reports it through
    /// `handlers.ready` — which is how the tests avoid claiming a fixed port on
    /// the machine running them.
    func start(port: UInt16) {
        queue.async { [self] in
            guard listener == nil, !isStopped else { return }
            requestedPort = port
            bindAttempts = 0
            bind()
        }
    }

    /// Stop listening and drop every client. Safe to call when not running, and
    /// final: a stopped server does not start again, because a retried bind may
    /// still be in flight behind it. The controller builds a fresh one to come
    /// back up, which is also what makes the PIN and the page it was handed
    /// current rather than whatever they were when it went down.
    func stop() {
        queue.async { [self] in
            isStopped = true
            dropListener()
            for client in clients.values { client.close(code: 1001) }
            clients.removeAll()
            lastStatus = nil
            lastTakeLog = nil
            // The clients are gone, so the demand is too — the app tears the
            // encoder down on this edge even when it forgot to on its own.
            multiviewDemandChanged()
        }
    }

    /// How many connections the server is holding a slot for.
    ///
    /// The cap on those slots is what stops a script pointed at the port from
    /// using up the app's file descriptors, so whether they come back is worth
    /// being able to ask directly rather than inferring from a connection that
    /// did or did not get through.
    var clientCount: Int {
        // Safe from any thread: nothing on this queue ever waits on another one.
        queue.sync { clients.count }
    }

    /// Push a status to every authenticated client.
    func broadcast(_ status: RemoteStatus) {
        let json = status.json
        queue.async { [self] in
            lastStatus = json
            for client in clients.values { client.send(text: json) }
        }
    }

    /// Push the take log to every authenticated client. It rides the same
    /// sockets `broadcast(_:)` does — telling the two apart is a message
    /// `type`, not a second channel — so both pages share the PIN gate, the
    /// replay-on-auth and the stalled-client discipline without a second copy
    /// of any of them.
    func broadcastTakeLog(_ log: RemoteTakeLog) {
        let json = log.json
        queue.async { [self] in
            lastTakeLog = json
            for client in clients.values { client.send(text: json) }
        }
    }

    /// Replace the served page — the operator changed the UI language, and the
    /// labels on the phone follow the app.
    func setPage(_ page: Data) {
        shared.withLock { $0.page = page }
    }

    /// Replace the script supervisor's page, for the same language switch.
    func setScriptPage(_ page: Data) {
        shared.withLock { $0.scriptPage = page }
    }

    /// Replace the camera grid's page, for the same language switch.
    func setCamerasPage(_ page: Data) {
        shared.withLock { $0.camerasPage = page }
    }

    /// Push one camera's fresh JPEG to every client that asked for frames.
    /// Fire-and-forget from the encoder's queue; each client applies its own
    /// one-in-flight rule, so a slow phone holds nothing up (see
    /// `RemoteClient+Multiview`).
    func broadcastFrame(camera: Int, jpeg: Data) {
        let index = UInt8(clamping: camera)
        queue.async { [self] in
            for client in clients.values { client.send(frame: jpeg, camera: index) }
        }
    }

    /// Replace the PIN. Sockets already authenticated stay open; their next
    /// command carries the old code and is refused, which is what a rotated
    /// code has to mean.
    func setPIN(_ pin: String) {
        shared.withLock { $0.pin = pin }
    }

    // MARK: - called by RemoteClient, on the same queue

    var currentPIN: String { shared.withLock { $0.pin } }
    var currentPage: Data { shared.withLock { $0.page } }
    var currentScriptPage: Data { shared.withLock { $0.scriptPage } }
    var currentCamerasPage: Data { shared.withLock { $0.camerasPage } }
    var currentStatus: String? { lastStatus }
    var currentTakeLog: String? { lastTakeLog }

    /// A client subscribed, unsubscribed or went away: recount, and tell the
    /// app only when the answer changed. Queue-confined, like the registry it
    /// reads.
    func multiviewDemandChanged() {
        let demand = clients.values.contains(where: \.wantsMultiview)
        guard demand != multiviewDemand else { return }
        multiviewDemand = demand
        handlers.multiviewDemand(demand)
    }

    /// Register one PIN verification and say how long its answer must be held
    /// back. Queue-confined, like the tarpit it reads.
    ///
    /// Every path that answers a PIN comes through here — the socket's
    /// handshake and the poster's query string alike. A second place that says
    /// yes or no to a code without paying for it is the same four digits with
    /// the delay switched off, and being the cheaper of the two is all an
    /// enumeration needs. The single exception is a socket re-presenting a code
    /// this server already accepted on it (see `RemoteClient.handle`), which
    /// answers nothing an attacker could reach without the code already.
    func notePINAttempt(failed: Bool) -> TimeInterval {
        tarpit.attempt(failed: failed, now: Self.monotonicNow())
    }

    /// Failures still inside the tarpit's window. For the tests; nothing in the
    /// server branches on it.
    var pinPressure: Int { queue.sync { tarpit.pressure } }

    /// The largest send ledger any client is carrying. For the tests, like
    /// `pinPressure`: a send whose completion has not landed yet counts
    /// against the drop ceiling, and this is the only place that fact lives —
    /// a test that pushes right behind a large message needs to poll the
    /// ledger down first or it drops the very client it is asserting alive.
    var maxClientInFlight: Int {
        queue.sync { clients.values.map(\.inFlightBytes).max() ?? 0 }
    }

    /// Frames handed to the transport, across all clients. For the tests —
    /// the one-in-flight rule is otherwise invisible from outside: a frame
    /// held back is indistinguishable on the wire from one not yet encoded.
    var multiviewFrameSends: Int {
        queue.sync { clients.values.map(\.frameSends).reduce(0, +) }
    }

    /// Clients with a frame handed over whose completion has not landed.
    /// For the tests, like the ledger above.
    var multiviewFramesInFlight: Int {
        queue.sync { clients.values.filter(\.frameInFlight).count }
    }

    /// The largest held-frame count any client is carrying — the latest-wins
    /// bound the tests assert: one per camera, however many frames were
    /// pushed while the socket stalled.
    var multiviewPendingFrames: Int {
        queue.sync { clients.values.map(\.pendingFrames.count).max() ?? 0 }
    }

    /// Seconds off a clock that only ever moves forward. The tarpit's window is
    /// measured against it rather than against `Date`, which an NTP correction
    /// or an operator setting the clock can move backwards — and a window whose
    /// clock jumps back is a window that never expires.
    static func monotonicNow() -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    func dispatch(_ command: RemoteCommand) {
        handlers.command(command)
    }

    func clientClosed(_ client: RemoteClient) {
        clients.removeValue(forKey: ObjectIdentifier(client))
        // A watcher that walked away is a demand change like any other: the
        // last one out is what lets the app stop encoding.
        multiviewDemandChanged()
    }
}
