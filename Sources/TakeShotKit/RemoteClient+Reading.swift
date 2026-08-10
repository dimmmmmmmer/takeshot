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
        case RemotePage.scriptPath:
            // The markup is as public as the operator page's — everything it
            // shows arrives over the socket, behind the same PIN.
            writeAndClose(RemoteResponse.page(server?.currentScriptPage ?? Data()))
        case RemotePage.camerasPath:
            // Same rule: the markup is empty tiles, and every frame that
            // could fill them rides the socket behind the PIN.
            writeAndClose(RemoteResponse.page(server?.currentCamerasPage ?? Data()))
        case RemotePage.posterPath:
            servePoster(request)
        default:
            writeAndClose(RemoteResponse.notFound())
        }
    }

    /// `GET /take-poster?pin=…&take=…` — a JPEG of one take's frame. Without a
    /// `take` it is the last take that landed, which is the operator page's
    /// card; the script page names the row it is drawing.
    ///
    /// The code travels in the query string because the page fetches this with
    /// an `<img>`, and an `<img>` carries no headers. That is the one place in
    /// this app where a PIN is in a URL, and it is exactly why the answer goes
    /// through the same tarpit the socket handshake does: an endpoint that says
    /// yes or no to a code for free is the same four digits with the delay
    /// switched off, and being the cheaper of the two is all an enumeration
    /// needs. Nothing logs the target, and the server hands out no referrer.
    ///
    /// The take id is gated behind the same code as everything else: a row's
    /// thumbnail is production picture exactly as the status is, and an image
    /// route that answered without the PIN would be the whole day's footage in
    /// stills to anyone who can reach the port.
    private func servePoster(_ request: RemoteRequest) {
        guard let server else {
            writeAndClose(RemoteResponse.notFound())
            return
        }
        let candidate = RemoteRequest.queryValue("pin", in: request.query) ?? ""
        let take = RemoteRequest.queryValue(RemotePage.posterTakeParameter,
                                            in: request.query) ?? ""
        // The same door the socket's handshake goes through, and never `exempt`:
        // an HTTP fetch has shown nothing this server can remember.
        switch server.checkPIN(candidate, peer: peer, exempt: false) {
        case .silent:
            // This peer already has a PIN answer on the way: the guess is
            // counted and this request gets no response at all. Closed rather
            // than left hanging — an unanswered fetch that kept its connection
            // slot for fifteen seconds would hand the enumeration the socket
            // exhaustion for free. An `<img>` reads a dropped connection
            // exactly as it reads the 404 it gets while a take's frame is still
            // decoding, and the page already retries that.
            close(code: nil)
        case .accepted(let hold):
            holdForTarpit(hold) { [weak self] in
                self?.answerPoster(accepted: true, take: take)
            }
        case .refused(let hold):
            holdForTarpit(hold) { [weak self] in
                self?.answerPoster(accepted: false, take: take)
            }
        }
    }

    private func answerPoster(accepted: Bool, take: String) {
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
        server.handlers.poster(take) { [weak server] jpeg in
            // Resolved HERE, once. A weak capture is a VARIABLE in the closure
            // that holds it, and reading it again from inside the queue hop
            // below would be two threads reading one variable — which is what
            // the compiler objects to, and it is right that it does.
            guard let server else { return }
            // The app builds the image where it keeps it, which is not this
            // queue. Everything in this class is queue-confined, so the reply
            // hops back before it touches any of it.
            queue.async { [weak server] in
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
