import Foundation

/// Bytes off the socket, and the HTTP half of what may be in them: the page
/// request, and the upgrade handshake that turns the connection into a socket.
///
/// Split out of `RemoteClient` — reading and answering an HTTP request is a
/// separate job from the WebSocket framing that follows it
/// (`RemoteClient+Frames`) and from the app protocol carried inside that.
extension RemoteClient {
    func receive() {
        connection.receive(minimumIncompleteLength: 1,
                           maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.ingest(data) }
            // A connection already on its way out owns its own cancel, and for a
            // response it is `writeAndClose` that owns it — once the bytes are on
            // the wire. Cancelling from here instead discards them, and `ingest`
            // above is exactly what leaves this closure looking at a closed
            // client: routing `GET /` sets the flag in the same turn. That is a
            // page request answered with a dropped connection.
            guard !self.closed else { return }
            guard !isComplete, error == nil else {
                self.close(code: nil)
                return
            }
            self.receive()
        }
    }

    private func ingest(_ data: Data) {
        buffer.append(data)
        guard buffer.count <= Self.maximumBuffer else {
            close(code: 1009)
            return
        }
        if upgraded {
            drainFrames()
        } else {
            drainRequest()
        }
    }

    private func drainRequest() {
        guard let end = RemoteRequest.headEnd(in: buffer) else { return }
        let head = Data(buffer[buffer.startIndex..<end])
        // Whatever followed the blank line stays: a browser can put its first
        // frame in the same packet as the upgrade request, and dropping it
        // loses the hello that carries the PIN.
        buffer = Data(buffer[end...])
        guard let request = RemoteRequest.parse(head) else {
            writeAndClose(RemoteResponse.badRequest())
            return
        }
        route(request)
    }

    private func route(_ request: RemoteRequest) {
        // RFC 6455 §4.1: the handshake is a GET. Upgrading anything else would
        // let a method nothing sends reach the socket path.
        if request.method == "GET", request.path == "/ws", request.isWebSocketUpgrade,
           let key = request.headers["sec-websocket-key"] {
            write(RemoteResponse.upgrade(key: key))
            upgraded = true
            drainFrames()
            return
        }
        guard request.method == "GET" else {
            writeAndClose(RemoteResponse.badRequest())
            return
        }
        switch request.path {
        case "/", "/index.html":
            writeAndClose(RemoteResponse.page(server?.currentPage ?? Data()))
        case RemotePage.posterPath:
            servePoster(request)
        default:
            writeAndClose(RemoteResponse.notFound())
        }
    }

    /// `GET /take-poster?pin=…` — a JPEG of the last take that landed.
    ///
    /// The code travels in the query string because the page fetches this with
    /// an `<img>`, and an `<img>` carries no headers. That is the one place in
    /// this app where a PIN is in a URL, and it is exactly why the answer goes
    /// through the same tarpit the socket handshake does: an endpoint that says
    /// yes or no to a code for free is the same four digits with the delay
    /// switched off, and being the cheaper of the two is all an enumeration
    /// needs. Nothing logs the target, and the server hands out no referrer.
    private func servePoster(_ request: RemoteRequest) {
        guard let server else {
            writeAndClose(RemoteResponse.notFound())
            return
        }
        let candidate = RemoteRequest.queryValue("pin", in: request.query) ?? ""
        let accepted = RemotePIN.matches(candidate, expected: server.currentPIN)
        holdForTarpit(server.notePINAttempt(failed: !accepted)) { [weak self] in
            self?.answerPoster(accepted: accepted)
        }
    }

    private func answerPoster(accepted: Bool) {
        guard accepted else {
            writeAndClose(RemoteResponse.forbidden())
            return
        }
        guard let server, let queue else {
            writeAndClose(RemoteResponse.notFound())
            return
        }
        // Nothing that is not Sendable crosses: the app is handed an identity,
        // and the connection is looked up again on the server's queue once the
        // answer comes back. A client dropped in the meantime is simply no
        // longer in the registry, which is the honest answer to "who asked for
        // this" — and it is cheaper than a box asserting that a queue-confined
        // object may be carried through another thread untouched.
        let id = ObjectIdentifier(self)
        server.handlers.poster { [weak server] jpeg in
            // The app builds the image where it keeps it, which is not this
            // queue. Everything in this class is queue-confined, so the reply
            // hops back before it touches any of it.
            queue.async {
                guard let client = server?.clients[id], !client.closed else {
                    return
                }
                guard let jpeg else {
                    // A take finalizes asynchronously and its frame is decoded
                    // off the main actor: "not yet" is an honest answer, and
                    // asking for it is what starts the decode. The page tries
                    // again while the status still names the same take.
                    client.writeAndClose(RemoteResponse.notFound())
                    return
                }
                client.writeAndClose(RemoteResponse.jpeg(jpeg))
            }
        }
    }
}
