import CaptureCore
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
        /// One WebRTC offer that passed the PIN check, and where to put the
        /// answer.
        ///
        /// Asked for on the server's queue and answered from wherever the app
        /// finishes gathering — which BLOCKS, and so is neither this queue nor
        /// the MainActor — so the reply is a closure the app calls back rather
        /// than a return value, exactly like `poster`. The default says the
        /// feature is absent, which is what a server driven without a
        /// controller has.
        var webrtcOffer: @Sendable (String, LivePicture,
                                    @escaping @Sendable (RemoteWebRTC.Answer)
                                        -> Void) -> Void
            = { _, _, reply in
                reply(.unavailable(L("live_no_app")))
            }
        /// One already-connected browser wants a different picture, and where
        /// to put the verdict.
        ///
        /// `false` means there is no such viewer, which the route answers 404
        /// to — see `RemoteClient.dispatchPictureChange` for why that is news
        /// rather than an error. Asked for on the server's queue and answered
        /// from the MainActor, like `poster`. The default says no, which is the
        /// truth for a server driven without a controller: it has no viewers.
        var webrtcPicture: @Sendable (String, LivePicture,
                                      @escaping @Sendable (Bool) -> Void) -> Void
            = { _, _, reply in reply(false) }
    }

    /// The values the app pushes in while the server runs: the PIN and the
    /// localized pages. All change without a restart (the operator switches
    /// language, or regenerates the code).
    private struct Shared {
        var pin: String
        var page: Data
        var scriptPage: Data
        var livePage: Data
        var slatePage: Data
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

    /// Commands the whole SET may have in hand at once, and how fast the
    /// allowance comes back.
    ///
    /// The per-socket ceiling in `RemoteClient` stops one runaway page; this one
    /// stops the crew, and the first does not bound the second: eight sockets
    /// each inside their own limit still reach a hundred and twenty-eight
    /// commands a second, and every `rate`, `comment` and `slate` among them
    /// rewrites four sidecar files on the volume the take is being written to.
    ///
    /// The burst is what the set can legitimately produce AT ONCE, and that is
    /// not eight times one page's burst. The bulk flush belongs to the script
    /// page — `flushPending` sends one comment and one slate per take when the
    /// socket comes back — and there is one script supervisor. Two such pages,
    /// a second person or the same person's phone and tablet, against the
    /// 200-take day the poster cache is sized for: 2 × 2 × 200 = 800, and 1024
    /// is the next power of two above it. Everything else on the set is buttons.
    ///
    /// The refill is what people do. Every message behind this protocol follows
    /// a tap or a field losing focus, so a busy set is a few a second across
    /// every phone on it; thirty-two is several times that, and a quarter of
    /// what the per-socket ceilings alone would allow.
    static let commandBurst = 1024.0
    static let commandsPerSecond = 32.0

    /// Read by `RemoteServer+Listener` as well as here, so module-internal
    /// rather than private — never wider than the module.
    let handlers: Handlers
    let queue = DispatchQueue(label: "com.takeshot.remote")
    /// How long a connection may sit without showing the PIN, handed to every
    /// connection this server accepts.
    ///
    /// Per server, and for one reason: so a test can watch the deadline FIRE
    /// rather than only the condition it asks. Fifteen seconds is fifteen
    /// seconds, and a defence whose timer is never armed is one uncovered line
    /// away from no defence at all. The app never passes anything but the
    /// default.
    let handshakeDeadline: DispatchTimeInterval
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
    /// The set's command allowance, and when it was last topped up.
    private var commandTokens = RemoteServer.commandBurst
    private var commandTokensAt = RemoteServer.monotonicNow()

    init(pin: String, page: Data, scriptPage: Data = Data(),
         livePage: Data = Data(),
         slatePage: Data = Data(), handlers: Handlers,
         handshakeDeadline: DispatchTimeInterval
            = RemoteClient.handshakeDeadline) {
        self.handlers = handlers
        self.handshakeDeadline = handshakeDeadline
        self.shared = OSAllocatedUnfairLock(
            initialState: Shared(pin: pin, page: page, scriptPage: scriptPage,
                                 livePage: livePage,
                                 slatePage: slatePage))
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

    /// Replace the live page, for the same language switch.
    func setLivePage(_ page: Data) {
        shared.withLock { $0.livePage = page }
    }

    /// Replace the slate's page, for the same language switch.
    func setSlatePage(_ page: Data) {
        shared.withLock { $0.slatePage = page }
    }

    /// Replace the PIN, and drop every socket that was holding the old one.
    ///
    /// Refusing their next COMMAND is not enough, because the pages that make
    /// rotation urgent send none: the slate and the live view show their code
    /// once at the handshake and from then on only receive. A phone parked on
    /// the slate went on getting the timecode, the take name and the frames
    /// after the code it used had been retired — which is the one thing an
    /// operator rotating a code is trying to stop.
    ///
    /// 1008 (policy violation) rather than 1001: the page is being turned away,
    /// not told the server is going down, and its reconnect asks for a code.
    func setPIN(_ pin: String) {
        shared.withLock { $0.pin = pin }
        queue.async { [self] in
            for client in clients.values { client.close(code: 1008) }
            clients.removeAll()
        }
    }

    // MARK: - called by RemoteClient, on the same queue

    var currentPIN: String { shared.withLock { $0.pin } }
    var currentPage: Data { shared.withLock { $0.page } }
    var currentScriptPage: Data { shared.withLock { $0.scriptPage } }
    var currentLivePage: Data { shared.withLock { $0.livePage } }
    var currentSlatePage: Data { shared.withLock { $0.slatePage } }
    var currentStatus: String? { lastStatus }
    var currentTakeLog: String? { lastTakeLog }

    /// **The one door a PIN is verified through.** Compares the code AND
    /// charges for having asked, in one step that cannot be half-used.
    ///
    /// It is one call rather than two because the two-call shape — compare, then
    /// remember to register the attempt — puts the tarpit's coverage in the
    /// hands of whoever writes the next endpoint. An endpoint that answers yes
    /// or no to a code for free is the same four digits with the delay switched
    /// off, and being the cheaper of the two is all an enumeration needs. There
    /// is no test here that lists today's endpoints, because a list of endpoints
    /// is itself a thing that goes stale; what is pinned instead is that the
    /// comparison happens in this file and nowhere else in `Sources`
    /// (`RemotePINDoorTests`).
    ///
    /// `exempt` is the single deliberate free answer: a socket re-presenting a
    /// code this server already accepted on it. It answers nothing an attacker
    /// could reach without the code already, and it is what keeps the
    /// operator's own REC button from going behind somebody else's guessing —
    /// see `RemoteClient.handle`. A code that no longer matches falls through
    /// and pays, so a socket authenticated with yesterday's PIN cannot walk
    /// today's for free.
    ///
    /// Queue-confined, like the tarpit it reads. `peer` is the source address,
    /// which is what makes the cost the guesser's rather than the set's.
    func checkPIN(_ candidate: String, peer: String,
                  exempt: Bool) -> RemotePINVerdict {
        let accepted = RemotePIN.matches(candidate, expected: currentPIN)
        if exempt, accepted { return .accepted(hold: 0) }
        guard let hold = tarpit.attempt(peer: peer, failed: !accepted,
                                        now: Self.monotonicNow()) else {
            return .silent
        }
        return accepted ? .accepted(hold: hold) : .refused(hold: hold)
    }

    /// Spend one command against the SET's allowance.
    ///
    /// Queue-confined: every caller is already on this queue, which is what
    /// lets one bucket be shared by every connection without a lock.
    func spendCommandAllowance() -> Bool {
        let now = Self.monotonicNow()
        commandTokens = min(Self.commandBurst,
                            commandTokens
                                + (now - commandTokensAt) * Self.commandsPerSecond)
        commandTokensAt = now
        guard commandTokens >= 1 else { return false }
        commandTokens -= 1
        return true
    }

    /// Spend the set's whole allowance and say how much that was, leaving it
    /// with nothing.
    ///
    /// For the tests, and it does two jobs there: the burst is a number in a
    /// comment until something counts it, and proving that two sockets share ONE
    /// bucket needs a server that has run out. Getting there by sending a
    /// thousand real commands would spend the suite's time rewriting sidecars to
    /// prove a token bucket.
    func drainCommandAllowance() -> Int {
        queue.sync {
            var spent = 0
            while spendCommandAllowance() { spent += 1 }
            return spent
        }
    }

    /// Failures still inside the tarpit's window, for the busiest peer. For the
    /// tests; nothing in the server branches on it.
    var pinPressure: Int { queue.sync { tarpit.pressure } }

    /// Whether any peer has a PIN answer on the way right now. For the tests,
    /// like `pinPressure`, and they need it: a peer may have only one answer
    /// outstanding, so a guess sent into an occupied slot is counted and never
    /// answered — a test that measures how long an answer took has to know the
    /// slot was free before it asked.
    var pinAnswerPending: Bool {
        queue.sync { tarpit.hasAnswerPending(now: Self.monotonicNow()) }
    }

    /// The source addresses the registry is holding, in no order.
    ///
    /// For the tests. The tarpit's ledger keys on this, and the key comes from
    /// `NWConnection.endpoint` being the REMOTE peer on a connection a listener
    /// accepted — an assumption about Network.framework that is worth one
    /// assertion against a real accepted socket rather than a comment.
    var clientPeers: [String] { queue.sync { clients.values.map(\.peer) } }

    /// Run every connection's handshake deadline now.
    ///
    /// For the tests, like `pinPressure`. The deadline is one `asyncAfter` per
    /// connection (`RemoteClient.start`) and it is fifteen seconds long; what
    /// is worth pinning is the condition it asks — a slot belongs to a page
    /// that showed the code — and not the clock behind it. Queue-confined, like
    /// the registry it walks.
    func sweepUnauthenticated() {
        queue.sync {
            for client in clients.values { client.closeIfUnauthenticated() }
        }
    }

    /// The largest send ledger any client is carrying. For the tests, like
    /// `pinPressure`: a send whose completion has not landed yet counts
    /// against the drop ceiling, and this is the only place that fact lives —
    /// a test that pushes right behind a large message needs to poll the
    /// ledger down first or it drops the very client it is asserting alive.
    var maxClientInFlight: Int {
        queue.sync { clients.values.map(\.inFlightBytes).max() ?? 0 }
    }

    /// Commands honoured, across all clients. For the tests, and for the same
    /// reason as the ledger below — see `RemoteClient.commandsHonoured`. The
    /// command ceiling is a RATE, so the only way to check it from outside is
    /// to count what got through and divide by the time it took.
    var commandsHonoured: Int {
        queue.sync { clients.values.map(\.commandsHonoured).reduce(0, +) }
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
    }
}

/// What `RemoteServer.checkPIN` answers: whether the code matched, and what
/// having asked costs.
///
/// An enum rather than a pair, so the third case cannot be forgotten — a peer
/// that already has an answer on the way is told nothing at all, and a caller
/// that treated that as "refused" would hand the enumeration back the reply it
/// was denied.
enum RemotePINVerdict: Equatable {
    /// The code matched. Deliver the answer after `hold` seconds.
    case accepted(hold: TimeInterval)
    /// The code did not match. Deliver the answer after `hold` seconds — the
    /// same wait an accepted one takes, or the clock becomes the oracle.
    case refused(hold: TimeInterval)
    /// Say nothing: this peer already has a PIN answer on the way.
    case silent
}
