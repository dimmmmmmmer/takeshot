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
        let path = target.prefix { $0 != "?" }
        return RemoteRequest(method: String(requestLine[0]).uppercased(),
                             path: path.isEmpty ? "/" : String(path),
                             headers: headers)
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
        head += "connect-src 'self' ws:\r\n"
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
