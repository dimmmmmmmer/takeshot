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
        if pendingRequest != nil {
            drainBody()
            return
        }
        guard let end = RemoteRequest.headEnd(in: buffer) else { return }
        let head = Data(buffer[buffer.startIndex..<end])
        // Whatever followed the blank line stays: a browser can put its first
        // frame in the same packet as the upgrade request, and dropping it
        // loses the hello that carries the PIN. A POST's body arrives the same
        // way, which is why it is read from here rather than from a second
        // receive.
        buffer = Data(buffer[end...])
        guard let request = RemoteRequest.parse(head) else {
            writeAndClose(RemoteResponse.badRequest())
            return
        }
        guard request.method == "POST" else {
            route(request, body: Data())
            return
        }
        // A body has to be announced and has to be small. The rule lives in
        // `RemoteWebRTC.bodyVerdict` rather than here — every case in it is a
        // boundary, and a boundary reachable only through a socket is a
        // boundary that gets one test instead of six.
        guard case .read(let announced) = RemoteWebRTC.bodyVerdict(
            contentLength: request.headers["content-length"]) else {
            writeAndClose(RemoteResponse.badRequest())
            return
        }
        pendingRequest = request
        pendingBodyLength = announced
        drainBody()
    }

    /// The body of a POST whose head has already been parsed, once all of it is
    /// here. Called again on every packet until it is.
    private func drainBody() {
        guard let request = pendingRequest,
              buffer.count >= pendingBodyLength else { return }
        let body = Data(buffer.prefix(pendingBodyLength))
        buffer = Data(buffer.dropFirst(pendingBodyLength))
        pendingRequest = nil
        pendingBodyLength = 0
        route(request, body: body)
    }

    /// The markup for one page route, or nil for a path that is not a page.
    ///
    /// Four routes that differ only in which page they hand back, lifted out
    /// of `route` so the router keeps one branch for the family. It is also
    /// the shape the complexity ceiling asked for when the root redirect made
    /// this five branches.
    ///
    /// Every one of them is as public as the others: the markup shows nothing
    /// on its own — the timecode, the take log, the video and the slate card
    /// all arrive over the socket, behind the PIN — so what is served here is
    /// an empty shell in every case.
    private func markup(for path: String) -> Data? {
        switch path {
        case RemotePage.remotePath: return server?.currentPage ?? Data()
        case RemotePage.scriptPath: return server?.currentScriptPage ?? Data()
        case RemotePage.livePath: return server?.currentLivePage ?? Data()
        case RemotePage.slatePath: return server?.currentSlatePage ?? Data()
        default: return nil
        }
    }

    private func route(_ request: RemoteRequest, body: Data) {
        // RFC 6455 §4.1: the handshake is a GET. Upgrading anything else would
        // let a method nothing sends reach the socket path.
        if request.method == "GET", request.path == "/ws", request.isWebSocketUpgrade,
           !request.isFromForeignOrigin,
           let key = request.headers["sec-websocket-key"] {
            write(RemoteResponse.upgrade(key: key))
            upgraded = true
            drainFrames()
            return
        }
        if request.method == "POST" {
            routePost(request, body: body)
            return
        }
        guard request.method == "GET" else {
            writeAndClose(RemoteResponse.badRequest())
            return
        }
        if let page = markup(for: request.path) {
            writeAndClose(RemoteResponse.page(page))
            return
        }
        switch request.path {
        case "/", "/index.html":
            // The operator page used to live at the root. A bare host still
            // has to land somewhere — a 404 for "the address of the app" is
            // the worst possible answer on a set — so it goes where the page
            // went, the way `/cameras` goes to the live page.
            writeAndClose(RemoteResponse.redirect(to: RemotePage.remotePath))
        case RemotePage.posterPath:
            servePoster(request)
        case "/cameras":
            // the JPEG grid's address, kept as a bookmark on crew phones
            writeAndClose(RemoteResponse.redirect(to: RemotePage.livePath))
        default:
            writeAndClose(RemoteResponse.notFound())
        }
    }

    /// The two POSTs this server answers, and they are the same page saying the
    /// same kind of thing: an offer in and an answer out (signalling entire —
    /// see `RemoteWebRTC` for why that is one request), and a picture change
    /// for a connection it already has.
    ///
    /// Its own function rather than two more branches in `route`, and the
    /// project's complexity ceiling is what said so: a router that grows a
    /// branch per route is the shape that ends up impossible to read, and the
    /// POSTs are a family of their own — same body ceiling, same PIN door, same
    /// tarpit. A path this does not know is a 400 exactly as it was when the
    /// method check answered it.
    private func routePost(_ request: RemoteRequest, body: Data) {
        switch request.path {
        case RemoteWebRTC.offerPath:
            serveWebRTCOffer(body)
        case RemoteWebRTC.picturePath:
            serveLivePictureChange(body)
        default:
            writeAndClose(RemoteResponse.badRequest())
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
        // The page is the OPERATOR's: the poster is the card on the operator
        // page, and it is the take's own frame — the one thing on the remote
        // that is footage rather than a readout.
        switch server.checkPIN(candidate, page: RemoteLink.remote.rawValue,
                               peer: peer, exempt: false) {
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
