import Foundation
import Network

/// One browser: the HTTP request that arrived on it, and the socket it may
/// become. Lives entirely on `RemoteServer`'s queue.
///
/// The status stream is behind the PIN, not just the commands. Timecode, the
/// take name and the day's marker count are production data — an unannounced
/// title, a cast name in a project prefix — and a page that shows them to
/// anyone who can reach the port is a leak that no amount of command checking
/// fixes. The cost of asking is one four-digit code per phone per shoot.
///
/// The socket is read in `RemoteClient+Reading` (bytes in, HTTP out) and its
/// frames are decoded in `RemoteClient+Frames`; this file is the connection
/// itself, what goes out on it, and the app protocol it carries. The state
/// below is module-internal rather than private for that reason — the two
/// extensions are the only readers, and it goes no wider than the module.
///
/// `@unchecked Sendable` for the same reason `RemoteServer` is, and under the
/// same rule: every member here — the buffer, the flags, the byte and answer
/// ledgers, the pending frames — is touched only on the server's serial queue.
/// The connection is started on it, `NWConnection` delivers its receive, send
/// and state callbacks on it because that is the queue it was started with, and
/// the two places where an answer comes back from somewhere else (the tarpit's
/// held answers, the poster reply) hop onto it before touching anything. There
/// is no lock here because there is nothing for a second thread to reach.
final class RemoteClient: @unchecked Sendable {
    /// Wrong codes tolerated on ONE socket before it is dropped.
    ///
    /// This is the cheap half and never was the defence: reconnecting costs
    /// nothing, so on its own the cap only makes every fifth guess buy a fresh
    /// TCP connection, and ten thousand combinations against eight sockets at a
    /// time still fall in seconds on a set network. What defends the REC button
    /// is `RemotePINTarpit` — a count the SERVER keeps, so no reconnect resets
    /// it, holding every PIN answer back by two seconds once a handful have
    /// failed, for a right code exactly as long as for a wrong one.
    ///
    /// Dropping the socket still earns its place either side of that: it returns
    /// the connection slot, and it tells a page carrying a code that has been
    /// rotated to stop retrying and ask for the new one.
    static let maximumBadPINs = 5
    /// Answers held back by the tarpit and not yet sent, per connection.
    ///
    /// The delay is on the answer, not on the reading — so a client can keep
    /// sending while one is outstanding, and a script pointed at the port will.
    /// The ceiling is what stops it from parking an unbounded number of timers
    /// on the server's queue. Above `maximumBadPINs` on purpose, so the socket
    /// still reaches its own cap; and the rule is the same for a right code and
    /// a wrong one, so a dropped message says nothing about either.
    static let maximumHeldAnswers = 8
    /// Ceiling on unparsed bytes. A request head that never ends, or frames
    /// that never complete, must not grow without limit on a machine that is
    /// recording.
    static let maximumBuffer = 128 * 1024
    /// How long a connection may sit without showing the PIN. The client cap
    /// exists to stop a script from exhausting the app's sockets, and without a
    /// deadline a half-open connection — a phone that slept during the
    /// handshake — holds one of those slots until TCP gives up hours later.
    ///
    /// It covers the UPGRADE as well as the request head, which it did not.
    /// "A WebSocket is meant to sit there all day" is true of an authenticated
    /// one and of nothing else: eight `curl`s that ask for `/ws` and then say
    /// nothing took every slot on the server for as long as the app ran, and no
    /// phone on the set could connect at all. Upgrading is free and anonymous;
    /// what a slot is FOR is a page that showed the code.
    ///
    /// Fifteen seconds is generous against what a real page does: it opens the
    /// socket only once it has a PIN to send (see `remote.html`'s `connect`),
    /// sends `hello` in `onopen`, and the slowest answer the server gives is
    /// the tarpit's two seconds.
    static let handshakeDeadline = DispatchTimeInterval.seconds(15)
    /// Ceiling on bytes handed to the transport but not yet accepted by it.
    ///
    /// A phone that walks out of Wi-Fi range does not send a FIN: the socket
    /// stays open, its window stays shut, and every status push after that only
    /// adds to a queue nobody is draining. This is about forty seconds of status
    /// at four a second — longer than a stall worth waiting through, and small
    /// enough that eight of them cannot matter to a machine that is recording.
    static let maximumInFlight = 32 * 1024
    /// How long a close frame is given to reach the phone before the connection
    /// is cancelled regardless. There has to be a deadline: the client that most
    /// needs closing is the one that stopped reading, and its send will never
    /// report itself done.
    static let closeFlushDeadline = DispatchTimeInterval.milliseconds(250)

    /// Commands a socket may have in hand at once, and how fast the allowance
    /// comes back.
    ///
    /// The ceiling is set above what the PAGES can produce and far below what a
    /// loop can. The largest legitimate burst there is comes from
    /// `script.html`'s `flushPending`, which fires every edit made while the
    /// socket was down the moment it comes back: one `comment` and one `slate`
    /// per take, and a shooting day's take list is bounded at 200 by the poster
    /// cache that has to hold one image for each of them — so 400, and 512 is
    /// the next power of two above it. The refill is what a person can do: every
    /// message behind this protocol follows a tap or a field losing focus, and
    /// sixteen a second is several times the fastest of those.
    ///
    /// A phone in a pocket, a page stuck in a retry loop, or a code that
    /// changed hands can otherwise turn one message into one rewrite of four
    /// sidecar files, hundreds of times a second, on the volume the take is
    /// being written to.
    static let commandBurst = 512.0
    static let commandsPerSecond = 16.0

    let connection: NWConnection
    weak var server: RemoteServer?
    /// The source address, as the tarpit's ledger keys on it. Read once here:
    /// `NWConnection.endpoint` is the remote peer for a connection a listener
    /// accepted, and it does not change under an open socket.
    ///
    /// An endpoint that is not a host and port leaves this empty, which puts
    /// every such peer in one bucket — the old server-wide behaviour, as the
    /// fallback rather than as the rule.
    let peer: String
    /// The server's queue, kept for the close-frame deadline and for the
    /// tarpit's held answers. Everything in this class already runs on it.
    var queue: DispatchQueue?

    var buffer = Data()
    var upgraded = false
    /// A request whose head has arrived and whose body has not.
    ///
    /// The one route that carries a body is the WebRTC offer, and a request
    /// head is not a request until the bytes it announced are here — so the
    /// parsed head waits with the length it is owed, and `drainRequest` finishes
    /// the job on whichever packet completes it. Nil for every GET, which is
    /// every other route.
    var pendingRequest: RemoteRequest?
    var pendingBodyLength = 0
    /// Read by `RemoteClient+Multiview` as well — the frame path must never
    /// serve a socket that has not shown the PIN. Written only here.
    private(set) var authenticated = false
    private var badPINs = 0
    /// No more protocol traffic goes out on this connection.
    var closed = false
    /// The server has been told this client is gone. Tracked apart from
    /// `closed`: a response whose send never completes leaves the client
    /// closed but still in the registry, holding a slot for good.
    private var unregistered = false
    /// Payload of a message split across frames. A browser will not fragment
    /// forty bytes, but a proxy between the phone and the laptop may.
    var fragment = Data()
    /// A fragmented message is open — the last data frame was not final, so the
    /// next one must be a continuation. Tracked rather than inferred from
    /// `fragment.isEmpty`: an empty first fragment is legal.
    var fragmentOpen = false
    /// Bytes sent but not yet processed by the transport. Queue-confined like
    /// everything else here: the send completion runs on the connection's queue,
    /// which is the server's.
    private var inFlight = 0
    /// The ledger, for the tests (via `RemoteServer.maxClientInFlight`);
    /// nothing in the server branches on it from outside `send`.
    var inFlightBytes: Int { inFlight }
    /// Tarpit answers scheduled on this connection and not yet delivered.
    private var heldAnswers = 0

    // MARK: - multiview state (see RemoteClient+Multiview for the behaviour)

    /// The socket asked for the camera-frame stream. Flipped in `settle` —
    /// behind the PIN, like everything else a message can ask for.
    private(set) var wantsMultiview = false
    /// A frame has been handed to the transport and its completion has not
    /// landed. THE one-in-flight rule: while this is true the next frame
    /// waits in `pendingFrames` instead of joining a queue. Module-internal
    /// like `buffer` — `RemoteClient+Multiview` is the only writer.
    var frameInFlight = false
    /// Newest undelivered frame per camera — latest wins, so a slow phone
    /// gets fewer frames, never older ones and never a growing backlog.
    var pendingFrames: [UInt8: Data] = [:]
    /// Frames actually handed to the transport. For the tests (via
    /// `RemoteServer.multiviewFrameSends`), like `inFlightBytes`.
    var frameSends = 0

    /// Command allowance left, and when it was last topped up.
    private var commandTokens = RemoteClient.commandBurst
    private var tokensAt = RemoteServer.monotonicNow()
    /// Commands this socket was actually allowed to spend. For the tests (via
    /// `RemoteServer.commandsHonoured`), like `inFlightBytes` and `frameSends`
    /// — the ceiling is otherwise invisible from outside, because a refused
    /// command is dropped SILENTLY and on purpose, so nothing on the wire
    /// tells a command the app ignored from one it applied to a value the take
    /// already had.
    private(set) var commandsHonoured = 0

    init(connection: NWConnection, server: RemoteServer) {
        self.connection = connection
        self.server = server
        self.peer = Self.address(of: connection.endpoint)
    }

    /// The host half of an endpoint, as a ledger key.
    static func address(of endpoint: NWEndpoint) -> String {
        guard case .hostPort(let host, _) = endpoint else { return "" }
        switch host {
        case .ipv4(let address): return "\(address)"
        case .ipv6(let address): return "\(address)"
        case .name(let name, _): return name
        @unknown default: return ""
        }
    }

    /// Spend one command's allowance, or say the socket is going too fast.
    ///
    /// A refused command is dropped and NOT answered: an error per refusal
    /// turns a flood into a reply flood, which is the thing `write`'s ceiling
    /// was just taught to refuse. The page finds out the honest way — the next
    /// status and take-log push carry what the app actually has.
    private func spendCommandAllowance() -> Bool {
        let now = RemoteServer.monotonicNow()
        commandTokens = min(Self.commandBurst,
                            commandTokens
                                + (now - tokensAt) * Self.commandsPerSecond)
        tokensAt = now
        guard commandTokens >= 1 else { return false }
        commandTokens -= 1
        commandsHonoured += 1
        return true
    }

    /// `deadline` is the server's — see `RemoteServer.handshakeDeadline` for why
    /// it is not simply read off `Self` here.
    func start(on queue: DispatchQueue, deadline: DispatchTimeInterval) {
        self.queue = queue
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.close(code: nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + deadline) { [weak self] in
            self?.closeIfUnauthenticated()
        }
        receive()
    }

    /// The half-open-connection sweep, run once per connection when
    /// `handshakeDeadline` passes: a socket that has not shown the PIN by then
    /// is holding one of eight slots for nothing, and the phones that need one
    /// are the ones that have the code.
    ///
    /// 1008 is "policy violation", the same code a refused PIN gets: the page
    /// then shows a refusal rather than sending the operator to look at the
    /// Wi-Fi. A connection that never upgraded has no frame to carry it and is
    /// simply cancelled — `close` decides that, not this.
    func closeIfUnauthenticated() {
        guard !authenticated, !unregistered else { return }
        close(code: 1008)
    }

    /// Send a status/notification frame. Silently does nothing until the client
    /// has upgraded and shown the PIN.
    ///
    /// A phone that has stopped draining its socket is dropped rather than
    /// buffered. It costs the other clients nothing to leave it — a broadcast
    /// walks them one after another and `NWConnection.send` never blocks — but it
    /// costs memory that grows for as long as the app runs, and the app is a
    /// recorder. See `maximumInFlight`.
    func send(text: String) {
        guard upgraded, authenticated, !closed else { return }
        write(RemoteWebSocketFrame.text(text))
    }

    /// Close the connection, with a WebSocket close frame when the socket got
    /// that far. `code` nil means the transport is already gone.
    ///
    /// The cancel waits for that frame, with `closeFlushDeadline` behind it.
    /// Cancelling in the same turn as the send discards what was sent — which is
    /// measured, not theoretical: it is what made `GET /` answer the browser with
    /// a dropped connection — and the close code is the difference between the
    /// page saying "wrong PIN" and the page sending the operator off to look at
    /// the Wi-Fi.
    func close(code: UInt16?) {
        let announce = !closed && upgraded ? code : nil
        closed = true
        // Unregistering must happen even for a client already marked closed by a
        // response still on its way out, or it holds a connection slot for good.
        guard !unregistered else { return }
        unregistered = true
        connection.stateUpdateHandler = nil
        server?.clientClosed(self)
        // Captured rather than reached through self: the registry has let go of
        // this client, and the frame still has to leave.
        let connection = self.connection
        guard let announce else {
            connection.cancel()
            return
        }
        connection.send(content: RemoteWebSocketFrame.close(code: announce),
                        completion: .contentProcessed { _ in connection.cancel() })
        queue?.asyncAfter(deadline: .now() + Self.closeFlushDeadline) {
            connection.cancel()
        }
    }

    // MARK: - the protocol itself

    func handle(text: String) {
        guard let message = RemoteMessage.parse(text) else {
            write(RemoteWebSocketFrame.text(
                #"{"type":"error","reason":"bad_message"}"#))
            return
        }
        guard let server else {
            // The server is gone; nothing on this socket can be verified
            // against anything, and it would otherwise sit here to its deadline.
            close(code: nil)
            return
        }
        // The one place this socket can find out whether a code matched, and it
        // charges for the asking. `exempt` is the socket already having shown
        // THIS code: holding its commands back would aim the tarpit at the one
        // phone the tarpit exists for — the unit with the code in it is the unit
        // that presses REC, and a REC button two seconds late loses the head of
        // a take for as long as somebody else keeps guessing.
        //
        // Verified now, answered when the tarpit says so. The whole answer goes
        // behind the delay, the dispatch included: a command that ran two
        // seconds before its own acknowledgement would put the status push in
        // front of it and time the two apart for whoever was watching.
        switch server.checkPIN(message.pin, peer: peer, exempt: authenticated) {
        case .silent:
            // This peer already has an answer on the way. The guess was counted
            // and nothing goes back — which is what stops eight sockets from
            // being eight times the guessing rate. The socket is left open
            // rather than closed: a page whose answer was swallowed because
            // something on its address was enumerating retries on its own
            // watchdog and gets in.
            return
        case .accepted(let hold):
            holdForTarpit(hold) { [weak self] in
                self?.settle(message, accepted: true)
            }
        case .refused(let hold):
            holdForTarpit(hold) { [weak self] in
                self?.settle(message, accepted: false)
            }
        }
    }

    /// One verified message: the handshake answer, then the command it carried.
    private func settle(_ message: RemoteMessage, accepted: Bool) {
        guard let server else { return }
        guard accepted else {
            refusePIN()
            return
        }
        if !authenticated {
            authenticated = true
            write(RemoteWebSocketFrame.text(#"{"type":"auth","ok":true}"#))
            // A phone picked up mid-take shows the take, not a blank readout,
            // without waiting for the next heartbeat.
            if let status = server.currentStatus {
                write(RemoteWebSocketFrame.text(status))
            }
            // And a script page opened mid-shift shows the day's takes, not an
            // empty table waiting for the next one to land.
            if let takeLog = server.currentTakeLog {
                write(RemoteWebSocketFrame.text(takeLog))
            }
        }
        // `hello` is the handshake and costs nothing; everything else is work
        // somebody's disk or main thread has to do, and is metered twice — once
        // against this socket, to stop one runaway page, and once against the
        // set, because eight sockets each inside their own limit are still a
        // hundred and twenty-eight sidecar rewrites a second on the volume the
        // take is being written to.
        guard message.command != .hello else { return }
        guard spendCommandAllowance(), server.spendCommandAllowance() else {
            return
        }
        // `multiview` was a per-connection subscription for the JPEG
        // `/cameras` page, which is gone: the live page carries the composed
        // grid as video and asks for a PICTURE, not for a frame stream. The
        // command is still parsed and still costs its allowance, so an old
        // page held open on somebody's phone is refused rather than crashing
        // a socket, and it reaches `dispatch` where every unknown verb does.
        server.dispatch(message.command)
    }

    /// Run `answer` now, or once the tarpit's delay has passed.
    ///
    /// The delay is on the answer and never on the queue. One serial queue
    /// carries every client's traffic, so a two-second wait taken on it would
    /// stop the timecode on every other phone on the set for as long as someone
    /// is guessing — which is the denial of service the tarpit is supposed to
    /// prevent, aimed the other way.
    /// `answer` is `@Sendable` because it is carried across an `asyncAfter` —
    /// onto the same serial queue it was made on, which is what makes writing
    /// it that way honest rather than merely accepted.
    func holdForTarpit(_ delay: TimeInterval,
                       _ answer: @escaping @Sendable () -> Void) {
        guard delay > 0, let queue else {
            answer()
            return
        }
        guard heldAnswers < Self.maximumHeldAnswers else { return }
        heldAnswers += 1
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.heldAnswers -= 1
            guard !self.closed else { return }
            answer()
        }
    }

    private func refusePIN() {
        badPINs += 1
        write(RemoteWebSocketFrame.text(#"{"type":"auth","ok":false}"#))
        guard badPINs >= Self.maximumBadPINs else { return }
        // 1008 is "policy violation" — the page shows it as a refusal rather
        // than as a network drop, so the operator is not sent to look at Wi-Fi.
        close(code: 1008)
    }

    // MARK: - writing

    func write(_ data: Data) {
        // The ceiling lives HERE and not in `send(text:)`, which is where it
        // used to be — the status stream was the only thing it covered, and the
        // status stream is the one thing on this socket that needs a PIN. A
        // pong and a `bad_message` are answered before authentication, they go
        // out through this method, and neither was counted against anything: a
        // peer that opens the socket, sends malformed frames as fast as the
        // wire allows and never reads had the app queueing replies until it
        // died, on a machine that is recording. The ceiling asks the same
        // question of every byte the protocol sends.
        guard inFlight < Self.maximumInFlight else {
            // 1011: the server is giving up on the socket, not on the phone. A
            // real page reconnects on its own and is sent a current status,
            // which is what something forty seconds behind wants anyway.
            close(code: 1011)
            return
        }
        // `contentProcessed` is Network.framework's backpressure signal: it fires
        // when the transport has room for more, which for a peer that stopped
        // reading is never. Counting the bytes between the send and that callback
        // is how a stalled socket becomes visible at all.
        inFlight += data.count
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            self?.inFlight -= data.count
        })
    }

    func writeAndClose(_ data: Data) {
        closed = true
        // Cancelled only once the bytes are on the wire: cancelling straight
        // after `send` loses the response the browser is waiting for.
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            self?.close(code: nil)
        })
    }
}
