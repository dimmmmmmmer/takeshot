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
final class RemoteClient {
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
    /// How long a connection may sit without finishing its request. The client
    /// cap exists to stop a script from exhausting the app's sockets, and
    /// without a deadline a half-open connection — a phone that slept during
    /// the handshake — holds one of those slots until TCP gives up hours later.
    /// Only pre-upgrade: a WebSocket is meant to sit there all day.
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

    let connection: NWConnection
    weak var server: RemoteServer?
    /// The server's queue, kept for the close-frame deadline and for the
    /// tarpit's held answers. Everything in this class already runs on it.
    var queue: DispatchQueue?

    var buffer = Data()
    var upgraded = false
    private var authenticated = false
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
    /// Tarpit answers scheduled on this connection and not yet delivered.
    private var heldAnswers = 0

    init(connection: NWConnection, server: RemoteServer) {
        self.connection = connection
        self.server = server
    }

    func start(on queue: DispatchQueue) {
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
        queue.asyncAfter(deadline: .now() + Self.handshakeDeadline) { [weak self] in
            guard let self, !self.upgraded, !self.unregistered else { return }
            self.close(code: nil)
        }
        receive()
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
        guard inFlight < Self.maximumInFlight else {
            // 1011: the server is giving up on the socket, not on the phone. The
            // page reconnects on its own and is sent a current status, which is
            // what something forty seconds behind wants anyway.
            close(code: 1011)
            return
        }
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
        let accepted = RemotePIN.matches(message.pin, expected: server.currentPIN)
        // A socket that already showed this code is not being verified again,
        // and holding its commands back would aim the tarpit at the one phone
        // the tarpit exists for. The unit with the code in it is the unit that
        // presses REC, and a REC button two seconds late loses the head of a
        // take — for as long as somebody else keeps guessing, which is a
        // lockout wearing a duration.
        //
        // Only a code that STILL matches takes this path. A rotated one falls
        // through and pays, so a socket authenticated with yesterday's PIN
        // cannot walk today's for free; and reaching the path at all costs a
        // valid code, so the stopwatch tells apart only what its holder knows.
        if authenticated, accepted {
            settle(message, accepted: true)
            return
        }
        // Verified now, answered when the tarpit says so. The whole answer goes
        // behind the delay, the dispatch included: a command that ran two
        // seconds before its own acknowledgement would put the status push in
        // front of it and time the two apart for whoever was watching.
        holdForTarpit(server.notePINAttempt(failed: !accepted)) { [weak self] in
            self?.settle(message, accepted: accepted)
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
        guard message.command != .hello else { return }
        server.dispatch(message.command)
    }

    /// Run `answer` now, or once the tarpit's delay has passed.
    ///
    /// The delay is on the answer and never on the queue. One serial queue
    /// carries every client's traffic, so a two-second wait taken on it would
    /// stop the timecode on every other phone on the set for as long as someone
    /// is guessing — which is the denial of service the tarpit is supposed to
    /// prevent, aimed the other way.
    func holdForTarpit(_ delay: TimeInterval, _ answer: @escaping () -> Void) {
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
