import Foundation
import Testing

@testable import TakeShotKit

/// Byte-level batteries for the surfaces raw set-network bytes reach first:
/// the hand-rolled HTTP head parser, its query reader, the client-message
/// JSON, and the PIN comparison. Deterministic throughout — the garbage comes
/// from a fixed-seed generator, so a red here reproduces.
@Suite struct RemoteTortureTests {
    /// xorshift64* — same bytes every run.
    private static func garbage(_ count: Int, seed: UInt64) -> Data {
        var state = seed
        var out = Data(capacity: count)
        while out.count < count {
            state ^= state >> 12
            state ^= state << 25
            state ^= state >> 27
            let word = state &* 0x2545_F491_4F6C_DD1D
            withUnsafeBytes(of: word.littleEndian) {
                out.append(contentsOf: $0.prefix(count - out.count))
            }
        }
        return out
    }

    // MARK: - the request head

    /// Every hostile head shape answers nil or a parsed request — never a trap,
    /// and never a request whose method or path is empty.
    @Test func requestHeadBatteryNeverCrashes() {
        let battery: [(String, Data)] = [
            ("empty", Data()),
            ("terminator alone", Data("\r\n\r\n".utf8)),
            ("method alone", Data("GET\r\n\r\n".utf8)),
            ("request line with one field", Data("GET \r\n\r\n".utf8)),
            ("no HTTP version", Data("GET /\r\nHost: x\r\n\r\n".utf8)),
            ("binary garbage", Self.garbage(4096, seed: 0xBAD_C0DE)),
            ("garbage with a terminator",
             Self.garbage(512, seed: 9) + Data("\r\n\r\n".utf8)),
            ("64 KB header line",
             Data("GET / HTTP/1.1\r\nX-Filler: ".utf8)
                + Data(repeating: 0x41, count: 65536) + Data("\r\n\r\n".utf8)),
            ("a thousand headers",
             Data(("GET / HTTP/1.1\r\n"
                + String(repeating: "A: b\r\n", count: 1000) + "\r\n").utf8)),
            ("colonless header", Data("GET / HTTP/1.1\r\nnocolonhere\r\n\r\n".utf8)),
            ("UTF-16 encoded head",
             Data("GET / HTTP/1.1\r\n\r\n".data(using: .utf16LittleEndian)!)),
        ]
        for (name, bytes) in battery {
            guard let end = RemoteRequest.headEnd(in: bytes) else { continue }
            guard let request = RemoteRequest.parse(Data(bytes[..<end]))
            else { continue }
            #expect(!request.method.isEmpty, "\(name)")
            #expect(!request.path.isEmpty, "\(name)")
        }
    }

    /// A target with spaces splits at the first one — the rest is discarded
    /// with the version field, not glued into the path.
    @Test func aTargetWithASpaceKeepsOnlyItsFirstWord() throws {
        let request = try #require(RemoteRequest.parse(
            Data("GET /a b HTTP/1.1\r\nHost: x\r\n\r\n".utf8)))
        #expect(request.path == "/a")
    }

    /// An empty target routes as "/" rather than as "" — the one page there is.
    @Test func anEmptyTargetRoutesAsTheRoot() throws {
        let request = try #require(RemoteRequest.parse(
            Data("GET ? HTTP/1.1\r\nHost: x\r\n\r\n".utf8)))
        #expect(request.path == "/")
        #expect(request.query.isEmpty)
    }

    // MARK: - the query reader

    /// Query-string junk: every shape answers a value or nil, and a value that
    /// will not percent-decode arrives raw rather than vanishing — the PIN
    /// check it feeds fails closed either way.
    @Test func queryReaderSurvivesTheBattery() {
        #expect(RemoteRequest.queryValue("pin", in: "&&&") == nil)
        #expect(RemoteRequest.queryValue("pin", in: "=1234") == nil)
        #expect(RemoteRequest.queryValue("pin", in: "pin==1") == "=1")
        #expect(RemoteRequest.queryValue("pin", in: "pin=") == "")
        #expect(RemoteRequest.queryValue("pin", in: "pin=%GG") == "%GG",
                "an undecodable value arrives raw, not dropped")
        #expect(RemoteRequest.queryValue("pin", in: "pin=1&pin=2") == "1",
                "the first occurrence wins, stably")
        #expect(RemoteRequest.queryValue("pin",
                                         in: "PIN=1234") == nil,
                "names are case-sensitive — no second spelling to guard")
        #expect(RemoteRequest.queryValue("pin", in: "pin=00%2034") == "00 34")
    }

    // MARK: - the client message

    /// Client JSON battery: none of these is a command, none of them traps.
    @Test func clientMessageBatteryParsesNothing() {
        let hostile = [
            "", " ", "null", "[]", "{}", "true", "0",
            "{\"action\":5,\"pin\":\"1\"}",
            "{\"action\":[\"rec\"],\"pin\":\"1\"}",
            "{\"action\":\"REC\",\"pin\":\"1\"}",
            "{\"action\":\"selfdestruct\",\"pin\":\"1\"}",
            "{\"action\":\"rec\"" + String(repeating: " ", count: 4096),
            String(repeating: "[", count: 100)
                + String(repeating: "]", count: 100),
            "{\"action\":\"rec\",",
        ]
        for text in hostile {
            #expect(RemoteMessage.parse(text) == nil,
                    "parsed a command out of: \(text.prefix(60))")
        }
    }

    /// Well-formed messages with a degenerate PIN field still fail closed: the
    /// command parses, the PIN it carries can never match a four-digit code.
    @Test func degeneratePINFieldsFailClosed() throws {
        // pin of the wrong JSON type reads as "" — refused by the match
        let numeric = try #require(RemoteMessage.parse(
            "{\"action\":\"rec\",\"pin\":1234}"))
        #expect(numeric == RemoteMessage(command: .rec, pin: ""))
        #expect(!RemotePIN.matches(numeric.pin, expected: "1234"))
        // a 64 KB pin parses and matches nothing
        let huge = try #require(RemoteMessage.parse(
            "{\"action\":\"rec\",\"pin\":\""
                + String(repeating: "9", count: 65536) + "\"}"))
        #expect(!RemotePIN.matches(huge.pin, expected: "9999"))
        // no pin field at all is an empty PIN, same refusal
        let bare = try #require(RemoteMessage.parse("{\"action\":\"marker\"}"))
        #expect(bare == RemoteMessage(command: .marker, pin: ""))
        #expect(!RemotePIN.matches(bare.pin, expected: "0000"))
    }

    // MARK: - the PIN comparison

    /// The constant-time comparison behaves at its edges: an empty expected
    /// code matches nothing (not even an empty candidate), length mismatches
    /// fail, and non-ASCII digits are not the digits the code is made of.
    @Test func pinComparisonEdges() {
        #expect(!RemotePIN.matches("", expected: ""))
        #expect(!RemotePIN.matches("1234", expected: ""))
        #expect(!RemotePIN.matches("123", expected: "1234"))
        #expect(!RemotePIN.matches("12345", expected: "1234"))
        #expect(!RemotePIN.matches("١٢٣٤", expected: "1234"),
                "Arabic-Indic digits are not the ASCII code")
        #expect(RemotePIN.matches("0007", expected: "0007"))
    }

    /// Every generated PIN is exactly four ASCII digits — the page's input
    /// field and the comparison above both assume it.
    @Test func generatedPINsAreAlwaysFourASCIIDigits() {
        for _ in 0..<64 {
            let pin = RemotePIN.generate()
            #expect(pin.count == 4)
            #expect(pin.allSatisfy { $0.isASCII && $0.isNumber })
        }
    }
}
