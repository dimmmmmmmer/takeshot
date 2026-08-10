import CaptureCore
import Darwin
import Foundation
import Testing

@testable import TakeShotKit

/// Shared scaffolding for the remote suites: bringing a listener up on an
/// ephemeral port, the clients that talk to it, and the probes that ask whether
/// a port is answering.
///
/// The listener always binds port 0 and the test reads back the ephemeral port it
/// got. A suite that claimed 8765 would fail on any machine where something else
/// had it, and on any machine running two copies of the suite.
@MainActor
enum RemoteHarness {
    /// Bring the server up and hand back the bound port and the PIN.
    static func serve(
        _ controller: CaptureController) async throws -> (port: Int, pin: String) {
        controller.startRemoteServer(overridePort: 0)
        let up = await ControllerWait.until { controller.remoteBoundPort > 0 }
        try #require(up, "the listener never reached ready")
        let pin = try #require(controller.settings.remote.pin)
        return (controller.remoteBoundPort, pin)
    }

    /// One take in the list, with a file behind it. The file matters: the folder
    /// scan runs at the suite's first `await` and retires any take whose footage
    /// it cannot find, which would empty the list under the test.
    @discardableResult
    static func seedTake(_ controller: CaptureController, in root: URL,
                         named name: String, clip: Int,
                         rating: TakeRating = .none,
                         markers: [TakeMarker] = []) throws -> Take {
        var take = ControllerFixtures.take(named: name, in: root, clip: clip)
        take.rating = rating
        take.markers = markers
        try ControllerFixtures.placeholder(for: take)
        controller.takes = [take]
        return take
    }

    /// Ephemeral: no cache or cookie store of the operator's is touched.
    static func session() -> URLSession {
        URLSession(configuration: .ephemeral)
    }

    /// A socket that has shown its PIN and had the handshake acknowledged.
    static func connect(port: Int, pin: String,
                        session: URLSession) async throws -> RemoteTestClient {
        let url = try #require(URL(string: "ws://127.0.0.1:\(port)/ws"))
        let client = RemoteTestClient(task: session.webSocketTask(with: url))
        client.task.resume()
        try await client.send(action: "hello", pin: pin)
        return client
    }

    /// One answer from the poster endpoint.
    ///
    /// `elapsed` is part of it because the endpoint is PIN-gated, and a
    /// PIN-gated endpoint that answers instantly is an oracle the socket's
    /// tarpit never sees — a suite has to be able to ask how long it took, not
    /// only what it said.
    struct PosterAnswer {
        var elapsed: Duration
        var http: HTTPURLResponse
        var body: Data
    }

    /// One fetch of a take poster, timed. `take` empty asks for the last take
    /// that landed, which is what the operator page's card wants.
    static func poster(port: Int, pin: String,
                       take: String = "") async throws -> PosterAnswer {
        let named = take.isEmpty
            ? "" : "&\(RemotePage.posterTakeParameter)=\(take)"
        let url = try #require(URL(
            string: "http://127.0.0.1:\(port)\(RemotePage.posterPath)?pin=\(pin)"
                + named))
        let started = ContinuousClock.now
        let (body, response) = try await session().data(from: url)
        let elapsed = started.duration(to: .now)
        return PosterAnswer(elapsed: elapsed,
                            http: try #require(response as? HTTPURLResponse),
                            body: body)
    }

    /// How long the server took to answer a PIN on a FRESH socket, and what it
    /// answered. Fresh every time on purpose: reconnecting is the move a
    /// per-socket cap cannot see, and the one the tarpit has to answer.
    static func measureAuth(port: Int, pin: String) async throws
        -> (elapsed: Duration, ok: Bool) {
        let url = try #require(URL(string: "ws://127.0.0.1:\(port)/ws"))
        let client = RemoteTestClient(
            task: session().webSocketTask(with: url))
        client.task.resume()
        defer { client.close() }
        let started = ContinuousClock.now
        try await client.send(action: "hello", pin: pin)
        let auth = try await client.next(type: "auth")
        return (started.duration(to: .now), auth["ok"] as? Bool == true)
    }

    /// A PIN that is not this one. Four digits, so there is always another.
    static func wrongPIN(besides pin: String) -> String {
        pin == "0000" ? "1111" : "0000"
    }

    /// Wait until no peer has a PIN answer on the way.
    ///
    /// A peer may have exactly one answer outstanding (`RemotePINTarpit`), and
    /// every socket in this suite comes from 127.0.0.1 — one peer. So a test
    /// that measures how long an answer took has to ask into a free slot, or it
    /// is measuring a guess that was counted and deliberately never answered.
    /// On a set network the phone and the guesser are different addresses and
    /// this does not arise; on loopback it is the whole difference between a
    /// measurement and a hang.
    static func pinSlotFree(_ server: RemoteServer) async -> Bool {
        await ControllerWait.until { !server.pinAnswerPending }
    }
}

/// A WebSocket client for the tests. `URLSessionWebSocketTask` does the
/// handshake, the masking and the ping replies, which is exactly the client
/// behaviour the server has to survive.
@MainActor
final class RemoteTestClient {
    let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func send(action: String, pin: String) async throws {
        try await task.send(.string(
            #"{"action":"\#(action)","pin":"\#(pin)"}"#))
    }

    /// A message of any shape — the script page's edits carry arguments beyond
    /// the action and the PIN.
    func send(_ object: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try await task.send(.string(
            try #require(String(bytes: data, encoding: .utf8))))
    }

    /// The next message of a given `type`, skipping anything else. Bounded, so
    /// a server that stops talking fails the test instead of hanging the suite.
    func next(type: String, within attempts: Int = 12) async throws -> [String: Any] {
        for _ in 0..<attempts {
            guard case .string(let text) = try await task.receive() else { continue }
            guard let object = try? JSONSerialization.jsonObject(
                with: Data(text.utf8)) as? [String: Any] else { continue }
            if object["type"] as? String == type { return object }
        }
        Issue.record("no \(type) message arrived")
        return [:]
    }

    func close() {
        task.cancel(with: .goingAway, reason: nil)
    }
}

/// A WebSocket client made of a plain socket, for the two things
/// `URLSessionWebSocketTask` will not do.
///
/// It reads the socket eagerly and buffers every frame in memory, so a test
/// using it can never present the server with a client that stopped draining;
/// and it validates what it is asked to send, so a frame sequence no browser
/// would produce cannot be written with it at all. Both are things the server
/// has to survive from a phone on a set network.
final class RemoteRawSocket {
    private var descriptor: Int32 = -1

    /// `receiveBuffer` shrinks the kernel's receive window on purpose: a test
    /// that wants the server to notice a client which stopped reading would
    /// otherwise have to push the machine's whole loopback buffer first.
    /// `readTimeout` keeps a read on a quiet socket from hanging the suite.
    init(port: Int, receiveBuffer: Int32 = 2048, readTimeout: Int = 3) throws {
        descriptor = socket(AF_INET, SOCK_STREAM, 0)
        try #require(descriptor >= 0, "socket() failed: \(errno)")
        var size = receiveBuffer
        setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &size,
                   socklen_t(MemoryLayout<Int32>.size))
        // A test that keeps writing while the server decides to drop the
        // connection is writing to a closed socket, and the default answer to
        // that is SIGPIPE — which kills the whole suite rather than failing one
        // assertion. The write reports the error instead.
        var noSignal: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                   socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: readTimeout, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                   socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(truncatingIfNeeded: port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0,
                               socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try #require(connected == 0, "connect() failed: \(errno)")
    }

    deinit { close() }

    func close() {
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor)
        descriptor = -1
    }

    /// The upgrade request, and the 101 that answers it.
    func handshake() throws {
        write(Data("""
        GET /ws HTTP/1.1\r
        Host: 127.0.0.1\r
        Upgrade: websocket\r
        Connection: Upgrade\r
        Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r
        Sec-WebSocket-Version: 13\r
        \r

        """.utf8))
        let response = try #require(read(), "the upgrade was never answered")
        let head = try #require(String(bytes: response, encoding: .utf8))
        try #require(head.hasPrefix("HTTP/1.1 101"), "no upgrade: \(head)")
    }

    /// A masked client frame, the way a browser sends them. Small payloads only —
    /// every message this protocol carries is forty bytes.
    func sendFrame(opcode: UInt8, payload: Data, isFinal: Bool = true) {
        let mask: [UInt8] = [0x2A, 0x11, 0x9C, 0x4D]
        precondition(payload.count < 126, "the raw client sends short frames only")
        var out = Data([(isFinal ? 0x80 : 0x00) | opcode])
        out.append(0x80 | UInt8(payload.count))
        out.append(contentsOf: mask)
        for (index, byte) in payload.enumerated() {
            out.append(byte ^ mask[index % 4])
        }
        write(out)
    }

    func sendHello(pin: String) {
        sendFrame(opcode: 0x1,
                  payload: Data(#"{"action":"hello","pin":"\#(pin)"}"#.utf8))
    }

    /// Bytes straight onto the wire, unvalidated. For the one thing
    /// `sendFrame` cannot do: hand over thousands of frames in one write, which
    /// is how a flood arrives and is nothing like a browser sending forty bytes
    /// at a time. False when the socket has gone — which is the answer a test
    /// flooding a server that may drop it needs, rather than a crash.
    @discardableResult
    func sendRaw(_ data: Data) -> Bool {
        write(data)
    }

    /// The code on the first close frame the server sends, or nil if it sends
    /// none. Server frames are unmasked, which is what makes this scan simple.
    func closeCode(within attempts: Int = 8) -> UInt16? {
        var stream = Data()
        for _ in 0..<attempts {
            guard let chunk = read() else { break }
            stream.append(chunk)
            var index = 0
            while index + 1 < stream.count {
                var length = Int(stream[index + 1] & 0x7F)
                var header = 2
                if length == 126 {
                    guard index + 4 <= stream.count else { break }
                    length = Int(stream[index + 2]) << 8 | Int(stream[index + 3])
                    header = 4
                }
                guard index + header + length <= stream.count else { break }
                if stream[index] & 0x0F == 0x8, length >= 2 {
                    return UInt16(stream[index + header]) << 8
                        | UInt16(stream[index + header + 1])
                }
                index += header + length
            }
        }
        return nil
    }

    /// Whatever is on the socket now, up to `limit` bytes. nil at end of stream
    /// and on the read timeout — a test asserts on what arrived, not on why
    /// nothing did.
    func read(limit: Int = 4096) -> Data? {
        var buffer = [UInt8](repeating: 0, count: limit)
        let count = Darwin.read(descriptor, &buffer, limit)
        guard count > 0 else { return nil }
        return Data(buffer[0..<count])
    }

    @discardableResult
    private func write(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            Darwin.write(descriptor, raw.baseAddress, raw.count) == raw.count
        }
    }
}

/// Whether the page answers at a port. Its own type because the port has to be
/// probed both ways round — up before the stop, gone after it.
enum HTTPURLProbe {
    static func url(port: Int) throws -> URL {
        try #require(URL(string: "http://127.0.0.1:\(port)/"))
    }

    static func reachable(_ url: URL) async -> Bool {
        let session = URLSession(configuration: .ephemeral)
        guard let (_, response) = try? await session.data(from: url) else {
            return false
        }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// Poll until the port refuses. Cancelling a listener is asynchronous, so
    /// the outcome is waited for rather than assumed on the next line.
    static func unreachableWithin(_ url: URL, attempts: Int = 20) async -> Bool {
        for _ in 0..<attempts {
            if await !reachable(url) { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }
}

/// What a second listener on a taken port reported. A box, because the server's
/// handlers run on its own queue.
final class RemoteFailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    private var readies = 0
    private var port: UInt16 = 0

    var message: String? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    var readyCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return readies
    }

    /// The port the listener reported binding; 0 until it does.
    var boundPort: UInt16 {
        lock.lock()
        defer { lock.unlock() }
        return port
    }

    func fail(_ message: String) {
        lock.lock()
        stored = message
        lock.unlock()
    }

    func bound(_ port: UInt16 = 0) {
        lock.lock()
        readies += 1
        self.port = port
        lock.unlock()
    }

    /// Handlers wired to this box, for a server driven without a controller.
    func handlers() -> RemoteServer.Handlers {
        RemoteServer.Handlers(command: { _ in },
                             ready: { [self] port in bound(port) },
                             failed: { [self] message in fail(message) })
    }
}
