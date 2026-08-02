import CryptoKit
import Foundation

/// The HTTP half of the remote: one request head, one response, and the
/// RFC 6455 upgrade handshake.
///
/// Hand-rolled on purpose. `NWProtocolWebSocket` performs the handshake for a
/// listener, but it performs it for EVERY connection the listener accepts — a
/// plain `GET /` for the page is then answered with a 400 and there is no way
/// to return a body from a rejected upgrade. The remote is one port and one URL
/// the operator can read off the screen, so the page and the socket have to
/// share a listener, and that means parsing the request head ourselves.
struct RemoteRequest: Equatable {
    var method: String
    /// Request target with any query string removed ("/ws?pin=1" → "/ws").
    var path: String
    /// Header names lowercased — HTTP header names are case-insensitive and
    /// browsers do not agree on the casing of `Sec-WebSocket-Key`.
    var headers: [String: String]
    /// Whatever followed the "?", raw and undecoded; empty when there was none.
    ///
    /// Kept apart from the path so routing can never be reached through it, and
    /// so the one endpoint that reads a parameter has to ask for it by name.
    var query: String = ""

    /// The end of the request head, or nil while it is still arriving.
    /// Returns the byte offset just past the blank line so the caller can keep
    /// whatever followed it — a browser can put the first WebSocket frame in
    /// the same packet as the upgrade request.
    static func headEnd(in buffer: Data) -> Int? {
        let terminator = Data([0x0D, 0x0A, 0x0D, 0x0A])
        guard let range = buffer.range(of: terminator) else { return nil }
        return range.upperBound
    }

    /// Parse a complete request head. nil for anything that is not a request
    /// line followed by headers.
    static func parse(_ head: Data) -> RemoteRequest? {
        // Failable on purpose: a head that is not valid UTF-8 is not an HTTP
        // request the app should guess at — the caller answers 400. Replacing
        // the bad bytes would invent a request line nobody sent.
        guard let text = String(bytes: head, encoding: .utf8) else { return nil }
        var lines = text.split(separator: "\r\n", omittingEmptySubsequences: true)
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let target = String(requestLine[1])
        let mark = target.firstIndex(of: "?")
        let path = mark.map { String(target[..<$0]) } ?? target
        return RemoteRequest(method: String(requestLine[0]).uppercased(),
                             path: path.isEmpty ? "/" : path,
                             headers: headers,
                             query: mark.map {
                                 String(target[target.index(after: $0)...])
                             } ?? "")
    }

    /// One parameter out of a query string, percent-decoding intact.
    ///
    /// Hand-rolled rather than `URLComponents`: this parses a request target off
    /// a socket, and `URLComponents` wants a URL — building one around
    /// attacker-supplied bytes to read four digits back out is more surface than
    /// the job needs. A value that will not decode is returned as it arrived
    /// rather than dropped; the only reader compares it against a PIN, which it
    /// will not match either way.
    static func queryValue(_ name: String, in query: String) -> String? {
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1,
                                   omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0] == name else { continue }
            return String(parts[1]).removingPercentEncoding ?? String(parts[1])
        }
        return nil
    }

    /// The request is a WebSocket upgrade.
    var isWebSocketUpgrade: Bool {
        headers["upgrade"]?.lowercased().contains("websocket") == true
            && headers["connection"]?.lowercased().contains("upgrade") == true
            && headers["sec-websocket-key"] != nil
    }
}

/// Responses the remote sends. Every one of them closes the connection after
/// the body: this serves one small page and then lives in the socket, so
/// keep-alive would only add a state machine nothing uses.
enum RemoteResponse {
    static func page(_ body: Data) -> Data {
        make(status: "200 OK", contentType: "text/html; charset=utf-8",
             body: body)
    }

    static func notFound() -> Data {
        make(status: "404 Not Found", contentType: "text/plain; charset=utf-8",
             body: Data("Not found\n".utf8))
    }

    /// The last take's poster frame. `no-store` comes with `make` and matters
    /// more here than on the page: the URL is stable across takes, and a phone
    /// handed the previous take's frame out of its own cache shows the director
    /// the wrong take with no way to tell.
    static func jpeg(_ body: Data) -> Data {
        make(status: "200 OK", contentType: "image/jpeg", body: body)
    }

    /// The PIN did not match. 403 rather than 404, because the two mean
    /// different things to the page: a stale code has to send the operator back
    /// to the gate, where "there is no frame yet" only has it try again.
    ///
    /// That this answer differs at all is an oracle, and an unavoidable one —
    /// an endpoint has to behave differently for a request it will serve. What
    /// makes it cost something is that it goes through the same tarpit the
    /// socket handshake does; see `RemotePINTarpit`.
    static func forbidden() -> Data {
        make(status: "403 Forbidden", contentType: "text/plain; charset=utf-8",
             body: Data("Forbidden\n".utf8))
    }

    static func badRequest() -> Data {
        make(status: "400 Bad Request", contentType: "text/plain; charset=utf-8",
             body: Data("Bad request\n".utf8))
    }

    private static func make(status: String, contentType: String,
                             body: Data) -> Data {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        // The page is the app's own state; a proxy or a phone holding a stale
        // copy of it after the port moved is a support call nobody can debug.
        head += "Cache-Control: no-store\r\n"
        // The page loads nothing from anywhere: saying so means a stray
        // <script src> introduced later fails loudly instead of phoning home
        // from the set network.
        head += "Content-Security-Policy: default-src 'none'; "
        head += "style-src 'unsafe-inline'; script-src 'unsafe-inline'; "
        // `img-src 'self'` is what lets the take poster load at all: under
        // `default-src 'none'` the browser blocks the <img> and reports it only
        // to a console on a phone, which looks exactly like an endpoint that is
        // answering 404. `blob:` is the multiview page's frames — bytes that
        // arrived over the socket and never left the page. 'self', blob: and
        // nothing else — the page still fetches nothing from off the set
        // network.
        head += "img-src 'self' blob:; connect-src 'self' ws:\r\n"
        head += "X-Content-Type-Options: nosniff\r\n"
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    /// The 101 that turns the connection into a socket.
    static func upgrade(key: String) -> Data {
        var head = "HTTP/1.1 101 Switching Protocols\r\n"
        head += "Upgrade: websocket\r\n"
        head += "Connection: Upgrade\r\n"
        head += "Sec-WebSocket-Accept: \(acceptKey(for: key))\r\n\r\n"
        return Data(head.utf8)
    }

    /// RFC 6455 §4.2.2: base64(SHA-1(key + GUID)). SHA-1 is not a security
    /// choice here — the value is a fixed handshake token every browser
    /// computes the same way, which is why CryptoKit spells it `Insecure`.
    static func acceptKey(for key: String) -> String {
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Insecure.SHA1.hash(data: Data((key + magic).utf8))
        return Data(digest).base64EncodedString()
    }
}
