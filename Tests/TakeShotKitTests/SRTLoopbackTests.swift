import CSRT
import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// The bridge against real libsrt, over the loopback interface.
///
/// **Why this exists.** Everything else about this feature can be checked without a
/// socket: the transport stream is bytes, the encoder is measurable through a
/// decode, and the mirror's discipline is a fake link away. What none of that
/// touches is the bridge itself — the `dlopen`, the option set in the order libsrt
/// demands, the handshake, the non-blocking accept, and whether a `send` returns
/// what this code thinks it returns. Those are the parts that would fail silently
/// on a set, and they cannot be reasoned about from here.
///
/// **What it does and does not prove.** Both ends are `CSRTSender`, which is an
/// output: the "receiver" is a caller socket nobody reads from. So this proves the
/// handshake completes over real UDP, the options are accepted, the accept poll
/// answers without blocking and a datagram is taken by the link. It does NOT prove
/// a receiver decodes the stream — that needs VLC or a gateway and a person, and
/// `vendor/SRTSDK/README.md` says so.
///
/// Runs ONLY where the headers are, which is a development machine and not CI.
/// It binds a real UDP port on the machine running it, in the same spirit as the
/// remote's listener tests — high, unassigned, and searched for rather than
/// assumed.
@Suite(.enabled(if: CSRTSender.isSDKAvailable(),
                "this build has no libsrt headers"))
struct SRTLoopbackTests {
    /// Ports to try, in order. A range rather than one number because a suite that
    /// failed when something else on the machine held a port would be reporting
    /// the machine.
    static let ports: [UInt16] = Array(41_000...41_049)

    /// One datagram through a sender, with the pointer dance in one place.
    private static func send(_ sender: CSRTSender,
                             _ datagram: Data) -> CSRTSendOutcome {
        datagram.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return CSRTSendOutcome.broken }
            return sender.sendDatagram(base, length: raw.count)
        }
    }

    /// A bound listener and the port it is on.
    private static func listener() throws -> (CSRTSender, UInt16) {
        for port in ports {
            let sender = CSRTSender(role: .listener, address: "", port: port,
                                    latencyMs: 120, passphrase: nil)
            if (try? sender.open()) != nil { return (sender, port) }
        }
        throw SRTStreamError.configuration("no free port in the test range")
    }

    /// The version tells us which runtime was loaded, which is the first thing
    /// worth knowing when a receiver cannot see a stream that says it is sending.
    @Test func theRuntimeReportsItsVersion() throws {
        let version: String = try #require(SRTStream.runtimeVersion)
        let parts: [String] = version.split(separator: ".").map(String.init)
        #expect(parts.count == 3, "the version does not read as x.y.z: \(version)")
        let major: Int = try #require(Int(parts[0]))
        let minor: Int = try #require(Int(parts[1]))
        // 1.5 or newer, which is what the vendor README asks for.
        #expect(major > 1 || (major == 1 && minor >= 5),
                "libsrt \(version) is older than this bridge expects")
        #expect(SRTStream.unavailableReason == nil)
    }

    /// **A real handshake and a real datagram.** A listener binds, a caller dials
    /// it over the loopback, and the listener's first send picks the peer up out of
    /// the accept queue and puts 1316 bytes on the wire.
    ///
    /// The whole option set is exercised on both sockets by getting this far:
    /// `SRTO_TRANSTYPE` before anything else, the latency, the payload size, and
    /// asynchronous sending — libsrt refuses any of them out of order or out of
    /// range, and every refusal is a `configuration` failure that would stop this
    /// test at `open`.
    @Test func aRealHandshakeCarriesARealDatagram() throws {
        let (server, port) = try Self.listener()
        defer { server.close() }
        let client = CSRTSender(role: .caller, address: "127.0.0.1", port: port,
                               latencyMs: 120, passphrase: nil)
        defer { client.close() }
        // Nobody has been accepted yet, so the listener has nowhere to send. This
        // is the poll answering rather than blocking, which is the property the
        // whole mirror rests on.
        let datagram = Data(MPEGTSMuxer.nullPacket
            + [UInt8](repeating: 0xFF, count: MPEGTSMuxer.datagramLength - 188))
        #expect(datagram.count == MPEGTSMuxer.datagramLength)
        let before: CSRTSendOutcome = Self.send(server, datagram)
        #expect(before == .noPeer, "a listener with no peer said \(before)")

        // …and now the handshake, over real UDP on the loopback. Blocking, with
        // libsrt's own connect timeout behind it.
        try client.open()
        var outcome: CSRTSendOutcome = .noPeer
        // The peer lands in the accept queue asynchronously, so the first send
        // after a connect may still be a poll that finds nothing.
        for _ in 0..<40 where outcome != .sent {
            outcome = Self.send(server, datagram)
            if outcome != .sent { usleep(50_000) }
        }
        #expect(outcome == .sent,
                "the datagram did not go out over loopback: \(outcome)")
        #expect(server.lastSendError == nil)
    }

    /// **A caller with nobody listening is a LINK failure and not a configuration
    /// one**, which is the distinction the reconnect loop is built on: this is the
    /// venue-network case that resolves itself when somebody opens VLC, so it is
    /// retried rather than shown as a thing to fix.
    ///
    /// Real, and slow on purpose: libsrt's connect timeout is what makes it slow,
    /// and that timeout is exactly why the connect is on the mirror's queue.
    @Test func aCallerWithNobodyListeningFailsAsARetryableLink() throws {
        // A port in the range with nothing on it. Found by binding and closing,
        // so the number is known to be free rather than hoped to be.
        let (probe, port) = try Self.listener()
        probe.close()
        let client = CSRTSender(role: .caller, address: "127.0.0.1", port: port,
                                latencyMs: 120, passphrase: nil)
        defer { client.close() }
        do {
            try client.open()
            Issue.record("a connect to nothing succeeded")
        } catch {
            let wrapped = error as NSError
            #expect(CSRTOpenFailure(rawValue: wrapped.code) == .link,
                    "a dead far end came back as code \(wrapped.code)")
            #expect(SRTStream.classify(error).isRetryable,
                    "a dead far end was not classed as retryable")
        }
    }

    /// An address that resolves to nothing is the operator's problem, so it is a
    /// CONFIGURATION failure and is not retried.
    @Test func anUnresolvableAddressIsAConfigurationFailure() throws {
        let client = CSRTSender(role: .caller,
                                address: "no-such-host.takeshot.invalid",
                                port: 9000, latencyMs: 120, passphrase: nil)
        defer { client.close() }
        do {
            try client.open()
            Issue.record("an unresolvable address opened")
        } catch {
            let wrapped = error as NSError
            #expect(CSRTOpenFailure(rawValue: wrapped.code) == .configuration)
            #expect(!SRTStream.classify(error).isRetryable)
        }
    }

    /// libsrt's own passphrase rule, met at the socket. The app checks it first so
    /// it can say so in the operator's language; this is the backstop, and it has
    /// to be a configuration failure or the reconnect loop would spin on it.
    @Test func aPassphraseSRTRefusesIsAConfigurationFailure() throws {
        let sender = CSRTSender(role: .listener, address: "", port: 41_099,
                                latencyMs: 120, passphrase: "short")
        defer { sender.close() }
        do {
            try sender.open()
            Issue.record("SRT accepted a five-character passphrase")
        } catch {
            let wrapped = error as NSError
            #expect(CSRTOpenFailure(rawValue: wrapped.code) == .configuration)
        }
    }

    /// A passphrase SRT DOES accept opens, which is what says the encryption path
    /// is wired rather than merely guarded.
    @Test func aPassphraseSRTAcceptsOpensTheLink() throws {
        for port in Self.ports {
            let sender = CSRTSender(role: .listener, address: "", port: port,
                                    latencyMs: 200,
                                    passphrase: "video-village-2026")
            defer { sender.close() }
            if (try? sender.open()) != nil { return }
        }
        Issue.record("an encrypted listener could not be opened on any port")
    }

    /// A closed listener frees its port. Not a formality: the operator switches
    /// this off and on again, and a port that stayed bound would make the second
    /// attempt a `configuration` failure the first attempt caused.
    @Test func closingAListenerFreesItsPort() throws {
        let (first, port) = try Self.listener()
        first.close()
        let second = CSRTSender(role: .listener, address: "", port: port,
                                latencyMs: 120, passphrase: nil)
        defer { second.close() }
        try second.open()
    }
}
