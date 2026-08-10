import Foundation
import Testing

@testable import TakeShotKit

/// What a connection can spend BEFORE it has shown the PIN.
///
/// The other remote suites ask what the server does for a phone that belongs
/// there. This one asks what it refuses to keep paying for, because everything
/// reachable before the code is reachable by anything that can open a socket to
/// the port — a laptop on the venue's Wi-Fi, a guest's phone, a scanner nobody
/// on the unit put there. Two resources are finite and neither is replaceable
/// mid-shoot: the eight connection slots the whole set shares, and the memory
/// of a machine that is recording.
///
/// Both tests below take the resource all the way to exhaustion and then
/// require a REAL phone to get in. An assertion that one anonymous socket was
/// dropped would have gone green against a server that still had seven slots
/// held by nothing.
@Suite @MainActor struct RemoteExhaustionTests {
    /// One arrival of six-byte masked text frames — the smallest frame a
    /// client can send, and one the server has to answer.
    ///
    /// An empty payload is valid UTF-8 and is not a command, so each of these
    /// buys a `bad_message` reply nearly seven times its own size. That is the
    /// cheapest way there is to make the server produce bytes without knowing
    /// the code.
    private static func junk(bytes: Int) -> Data {
        let frame = Data([0x81, 0x80, 0x2A, 0x11, 0x9C, 0x4D])
        var out = Data(capacity: bytes + frame.count)
        while out.count < bytes { out.append(frame) }
        return out
    }

    /// Every slot taken by a socket that upgraded and then said nothing.
    ///
    /// Upgrading costs nothing and proves nothing, and the half-open deadline
    /// used to stop watching the moment it happened — so these sockets held
    /// every slot on the server for as long as the app ran. On set that is no
    /// REC from the director, no script page and no camera grid, with nothing
    /// on the operator's screen to say why: it reads as the Wi-Fi.
    ///
    /// The deadline's own body is run here rather than waited out. Fifteen
    /// seconds is fifteen seconds, and what is worth pinning is the condition
    /// it asks and what freeing the slots gives back — that the timer is armed
    /// at `handshakeDeadline` is one line in `RemoteClient.start` and is NOT
    /// covered here.
    @Test func anonymousSocketsCannotHoldTheSetOutOfItsOwnRemote() async throws {
        try await ControllerHarness.run { controller, _ in
            let served = try await RemoteHarness.serve(controller)
            let server: RemoteServer = try #require(controller.remoteServer)

            var squatters: [RemoteRawSocket] = []
            defer { for socket in squatters { socket.close() } }
            for _ in 0..<RemoteServer.maximumClients {
                let socket = try RemoteRawSocket(port: served.port)
                try socket.handshake()
                squatters.append(socket)
            }
            let full: Bool = await ControllerWait.until {
                server.clientCount == RemoteServer.maximumClients
            }
            try #require(full, "the anonymous sockets never filled the registry")

            // The set is now locked out, and this is the half that makes the
            // rest of the test mean something.
            let url: URL = try HTTPURLProbe.url(port: served.port)
            let gotIn: Bool = await HTTPURLProbe.reachable(url)
            #expect(!gotIn, "eight anonymous sockets did not actually fill the server")

            server.sweepUnauthenticated()
            let freed: Bool = await ControllerWait.until {
                server.clientCount == 0
            }
            try #require(freed, "the sweep did not return the slots")

            // A real phone, all the way through the PIN.
            let phone = try await RemoteHarness.connect(
                port: served.port, pin: served.pin,
                session: RemoteHarness.session())
            defer { phone.close() }
            let auth: [String: Any] = try await phone.next(type: "auth")
            #expect(auth["ok"] as? Bool == true,
                    "a phone with the code still could not get on the remote")
        }
    }

    /// The other half, and the risk the deadline carries: a phone that DID show
    /// the code is meant to sit on its socket all day. A sweep that took it
    /// would turn every quiet moment on set into a reconnect.
    @Test func aPhoneThatShowedTheCodeKeepsItsSocket() async throws {
        try await ControllerHarness.run { controller, _ in
            let served = try await RemoteHarness.serve(controller)
            let server: RemoteServer = try #require(controller.remoteServer)
            let client = try await RemoteHarness.connect(
                port: served.port, pin: served.pin,
                session: RemoteHarness.session())
            defer { client.close() }
            let auth: [String: Any] = try await client.next(type: "auth")
            try #require(auth["ok"] as? Bool == true, "the phone never authenticated")

            server.sweepUnauthenticated()
            let kept: Bool = await ControllerWait.until {
                server.clientCount == 1
            }
            #expect(kept, "the deadline swept a phone that had shown the code")
        }
    }

    /// A peer that opens the socket, sends nonsense as fast as the wire allows
    /// and never reads it back.
    ///
    /// Every one of those frames is answered, and the answers are the app's
    /// memory: the in-flight ceiling used to be asked only about the STATUS
    /// stream, which is the one thing on this socket that already needs a PIN.
    /// A pong and a `bad_message` went out without being counted against
    /// anything, so the queue behind a peer that had stopped reading grew for
    /// as long as it kept typing — on a machine that is recording.
    ///
    /// Bounded on both sides: the flood stops at two megabytes, which is more
    /// than a loopback socket's buffers can swallow by an order of magnitude,
    /// and the assertion is that the slot came back rather than what the close
    /// code said — the socket is full of replies it never read, so the close
    /// frame is behind all of them. Then a real phone connects, because "the
    /// bound held" and "the server still works" are two claims.
    @Test func aFloodBeforeAuthenticatingCostsTheFlooderAndNobodyElse() async throws {
        try await ControllerHarness.run { controller, _ in
            let served = try await RemoteHarness.serve(controller)
            let server: RemoteServer = try #require(controller.remoteServer)
            let socket = try RemoteRawSocket(port: served.port)
            defer { socket.close() }
            try socket.handshake()
            let joined: Bool = await ControllerWait.until {
                server.clientCount == 1
            }
            try #require(joined, "the flooding socket never reached the registry")

            let chunk: Data = Self.junk(bytes: 32 * 1024)
            var dropped = false
            var rounds = 0
            while !dropped, rounds < 64 {
                rounds += 1
                guard socket.sendRaw(chunk) else { break }
                dropped = await ControllerWait.until(
                    { server.clientCount == 0 }, timeout: .milliseconds(200))
            }
            #expect(dropped, "replies to an unauthenticated peer were queued without limit")

            let phone = try await RemoteHarness.connect(
                port: served.port, pin: served.pin,
                session: RemoteHarness.session())
            defer { phone.close() }
            let auth: [String: Any] = try await phone.next(type: "auth")
            #expect(auth["ok"] as? Bool == true,
                    "the flood cost a phone with the code its way in")
        }
    }
}

/// What it costs to take frames out of one arrival.
///
/// Draining used to copy the unread remainder once per frame, in both halves —
/// the decoder took a `[UInt8]` of its whole argument and the caller rebuilt the
/// buffer after every frame — so absorbing input got slower the more of it
/// arrived at once, and how many frames one arrival holds is the client's
/// choice. Eight sockets between them needed about five megabytes a second to
/// own the server's one serial queue, which carries every phone's timecode,
/// REC press and camera tile.
///
/// **This asserts a RATIO and not a duration**, which is the only shape of
/// timing assertion this suite can carry honestly: it shares a machine with
/// whatever else is building, so an absolute millisecond budget is a flake with
/// a schedule (see `MultiviewPerformanceTests`, which prints rather than
/// asserts for exactly that reason). A ratio between two runs of the same work
/// on the same machine moments apart moves with neither the machine nor the
/// load.
///
/// The bound is where it is because of the RUNNER, which is slower and noisier
/// than any development machine and is the only place the test target is
/// compiled at all. Measured here, eight times the input cost fifty-one times
/// the time before the fix and nine times after — so anything from about twelve
/// to about forty separates the two shapes. Twenty-five sits in the middle of
/// that on a log scale: nearly three times the headroom above a passing nine,
/// and still half the distance to a failing fifty-one. A tighter bound would be
/// discovered as a flake by whoever is shooting that day, and the thing being
/// caught is a change of SHAPE, which moves by a factor of five, not by twenty
/// per cent.
///
/// The minimum of several runs, like the encoder benchmarks: the fastest run is
/// the one that got a whole core to itself, and it is what compares across
/// builds. Seven of them rather than five, for the same reason the bound is
/// loose — the runner needs more samples before one of them is clean.
struct RemoteDrainCostTests {
    /// One masked ping with an empty payload: six bytes, the floor.
    private static let ping = Data([0x89, 0x80, 0x2A, 0x11, 0x9C, 0x4D])

    /// The smaller arrival is what `receive` actually hands over at most; the
    /// larger is what the buffer ceiling allows, and is here because the read
    /// size is a constant somebody could reasonably raise.
    private static let small = 16 * 1024
    private static let large = 128 * 1024

    /// Quadratic draining would have to be worse than this. See the type's own
    /// comment for why it sits where it does: the shapes it separates measured
    /// 51 and 9, and the runner gets the benefit of the doubt.
    private static let worstRatio = 25.0
    /// Samples per arrival. The fastest is the one that got a core to itself.
    private static let runs = 7

    /// The correctness half, and the assumption the cost half rests on: the
    /// decoder reads a SLICE from that slice's own start.
    ///
    /// A Data slice keeps the indices of the buffer it came from, so a decoder
    /// that read absolute indices — or a `Data.withUnsafeBytes` that quietly
    /// flattened a slice into a copy — would turn the moving offset below back
    /// into the per-frame copy the fix removed. This is what says it does not.
    @Test func framesDecodeFromASliceAtAMovingOffset() throws {
        var stream = Self.masked(opcode: 0x1, payload: Data("one".utf8))
        stream.append(Self.masked(opcode: 0x1, payload: Data("two".utf8)))
        stream.append(Self.masked(opcode: 0x9, payload: Data()))

        var offset: Data.Index = stream.startIndex
        var payloads: [String] = []
        while let decoded =
            try RemoteWebSocketFrame.decode(from: stream[offset...]) {
            let text: String = try #require(
                String(bytes: decoded.frame.payload, encoding: .utf8))
            payloads.append(text)
            offset += decoded.consumed
        }

        #expect(payloads == ["one", "two", ""])
        #expect(offset == stream.endIndex, "the drain lost track of the stream")
    }

    /// One masked client frame, the way a browser sends them.
    private static func masked(opcode: UInt8, payload: Data) -> Data {
        let mask: [UInt8] = [0x2A, 0x11, 0x9C, 0x4D]
        var out = Data([0x80 | opcode, 0x80 | UInt8(payload.count)])
        out.append(contentsOf: mask)
        for (index, byte) in payload.enumerated() {
            out.append(byte ^ mask[index % 4])
        }
        return out
    }

    @Test func drainingCostsTheBytesAndNotTheSquareOfTheFrames() throws {
        let smallMs: Double = try Self.best(arrival: Self.small)
        let largeMs: Double = try Self.best(arrival: Self.large)
        let ratio: Double = largeMs / max(smallMs, 0.000_001)
        print(String(format: "REMOTEDRAIN %d KB %.3f ms, %d KB %.3f ms, ratio %.1f for 8x the input",
                     Self.small / 1024, smallMs, Self.large / 1024, largeMs, ratio))
        #expect(ratio < Self.worstRatio,
                "draining got slower per byte as the arrival grew, which is the copy per frame")
    }

    /// Fastest of five drains of one arrival, in milliseconds.
    private static func best(arrival: Int) throws -> Double {
        var buffer = Data()
        while buffer.count < arrival { buffer.append(ping) }
        var fastest = Double.infinity
        for _ in 0..<runs {
            let started = DispatchTime.now().uptimeNanoseconds
            let frames: Int = try drain(buffer)
            let elapsed = DispatchTime.now().uptimeNanoseconds - started
            try #require(frames == buffer.count / ping.count,
                         "the drain did not read the whole arrival")
            fastest = min(fastest, Double(elapsed) / 1_000_000)
        }
        return fastest
    }

    /// The decoder driven the way `RemoteClient.drainFrames` drives it: one
    /// call per frame against the same arrival, at a moving offset.
    private static func drain(_ buffer: Data) throws -> Int {
        var offset: Data.Index = buffer.startIndex
        var frames = 0
        while true {
            guard let decoded =
                try RemoteWebSocketFrame.decode(from: buffer[offset...])
            else { return frames }
            offset += decoded.consumed
            frames += 1
        }
    }
}
