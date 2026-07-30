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
        default:
            writeAndClose(RemoteResponse.notFound())
        }
    }
}
