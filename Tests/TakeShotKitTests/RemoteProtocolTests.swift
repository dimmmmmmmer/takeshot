import Foundation
import JavaScriptCore
import Testing

@testable import TakeShotKit

/// The wire formats the remote speaks, on their own: an HTTP request head, an
/// RFC 6455 frame, the JSON both ways. None of this needs a socket, and all of
/// it is the kind of code that fails silently — a frame decoded one byte off
/// reads as a browser that "just doesn't connect".
@Suite struct RemoteProtocolTests {
    /// Bytes as text, failing the test rather than papering over bad UTF-8 with
    /// replacement characters — a frame decoded one byte off would otherwise
    /// still compare "equal enough" to something.
    private func utf8(_ data: Data) throws -> String {
        try #require(String(bytes: data, encoding: .utf8))
    }

    // MARK: - HTTP

    /// The published RFC 6455 §1.3 example. If this value ever changes, no
    /// browser will complete the handshake, and the only symptom is a page that
    /// never goes green.
    @Test func theHandshakeMatchesTheSpecExample() {
        #expect(RemoteResponse.acceptKey(for: "dGhlIHNhbXBsZSBub25jZQ==")
            == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    @Test func aRequestHeadIsParsedWithItsHeadersLowercased() throws {
        let head = Data("""
        GET /ws?pin=1234 HTTP/1.1\r
        Host: 192.168.1.5:8765\r
        Upgrade: WebSocket\r
        Connection: keep-alive, Upgrade\r
        Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r
        \r

        """.utf8)
        let end = try #require(RemoteRequest.headEnd(in: head))
        let request = try #require(RemoteRequest.parse(Data(head[..<end])))

        #expect(request.method == "GET")
        // The query string is not part of the route — the PIN never travels in
        // a URL, but a client that puts something there must still be routed.
        #expect(request.path == "/ws")
        #expect(request.headers["host"] == "192.168.1.5:8765")
        #expect(request.isWebSocketUpgrade)
    }

    @Test func anIncompleteHeadIsNotParsedYet() {
        let partial = Data("GET / HTTP/1.1\r\nHost: x\r\n".utf8)
        #expect(RemoteRequest.headEnd(in: partial) == nil)
    }

    @Test func aPlainGetIsNotMistakenForAnUpgrade() throws {
        let head = Data("GET / HTTP/1.1\r\nHost: x\r\n\r\n".utf8)
        let request = try #require(RemoteRequest.parse(head))
        #expect(!request.isWebSocketUpgrade)
        #expect(request.path == "/")
    }

    /// The page must state that it loads nothing: a `<script src>` added later
    /// then fails loudly instead of reaching off the set network.
    @Test func theResponseHeadersLockThePageDown() throws {
        let text = try utf8(RemoteResponse.page(Data("hi".utf8)))
        #expect(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(text.contains("Content-Length: 2\r\n"))
        #expect(text.contains("default-src 'none'"))
        #expect(text.contains("X-Content-Type-Options: nosniff"))
        #expect(text.hasSuffix("hi"))
    }

    // MARK: - framing

    /// A client frame, masked the way every browser masks: this is the shape
    /// the decoder has to accept.
    private func clientFrame(opcode: UInt8, payload: Data,
                             mask: [UInt8] = [0x37, 0xFA, 0x21, 0x3D]) -> Data {
        var out = Data([0x80 | opcode])
        let count = payload.count
        if count < 126 {
            out.append(0x80 | UInt8(count))
        } else {
            out.append(0x80 | 126)
            out.append(UInt8(count >> 8))
            out.append(UInt8(count & 0xFF))
        }
        out.append(contentsOf: mask)
        for (index, byte) in payload.enumerated() {
            out.append(byte ^ mask[index % 4])
        }
        return out
    }

    @Test func aMaskedTextFrameDecodesToItsPayload() throws {
        let frame = clientFrame(opcode: 0x1, payload: Data("Hello".utf8))
        let decoded = try #require(try RemoteWebSocketFrame.decode(from: frame))

        #expect(decoded.consumed == frame.count)
        #expect(decoded.frame.opcode == .text)
        #expect(decoded.frame.isFinal)
        #expect(try utf8(decoded.frame.payload) == "Hello")
    }

    /// Two frames in one packet is normal on a slow link, and a decoder that
    /// only ever reads the first one loses every second command.
    @Test func framesAreDrainedOneAfterAnother() throws {
        var stream = clientFrame(opcode: 0x1, payload: Data("one".utf8))
        stream.append(clientFrame(opcode: 0x1, payload: Data("two".utf8)))

        let first = try #require(try RemoteWebSocketFrame.decode(from: stream))
        let rest = Data(stream[first.consumed...])
        let second = try #require(try RemoteWebSocketFrame.decode(from: rest))

        #expect(try utf8(first.frame.payload) == "one")
        #expect(try utf8(second.frame.payload) == "two")
        #expect(second.consumed == rest.count)
    }

    @Test func aHalfArrivedFrameWaitsInsteadOfThrowing() throws {
        let frame = clientFrame(opcode: 0x1, payload: Data("Hello".utf8))
        #expect(try RemoteWebSocketFrame.decode(from: Data(frame.dropLast(2)))
            == nil)
    }

    /// RFC 6455 §5.1. An unmasked frame is either a broken client or another
    /// protocol at the port; neither may be interpreted as a command.
    @Test func anUnmaskedClientFrameIsRefused() {
        let frame = RemoteWebSocketFrame.encode(opcode: .text,
                                                payload: Data("Hello".utf8))
        #expect(throws: RemoteFrameError.notMasked) {
            _ = try RemoteWebSocketFrame.decode(from: frame)
        }
    }

    /// Without the ceiling, one header claiming a huge length has the server
    /// buffering until the app is killed — on a machine that is recording.
    @Test func anOversizedFrameIsRefusedBeforeItIsRead() {
        var header = Data([0x81, 0xFF])
        header.append(contentsOf: [0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00])
        header.append(contentsOf: [0, 0, 0, 0])
        #expect(throws: RemoteFrameError.tooLarge) {
            _ = try RemoteWebSocketFrame.decode(from: header)
        }
    }

    @Test func serverFramesUseTheRightLengthForm() {
        let short = RemoteWebSocketFrame.encode(opcode: .text,
                                                payload: Data(count: 5))
        let medium = RemoteWebSocketFrame.encode(opcode: .text,
                                                 payload: Data(count: 200))
        let long = RemoteWebSocketFrame.encode(opcode: .text,
                                               payload: Data(count: 70_000))

        #expect(Array(short.prefix(2)) == [0x81, 5])
        #expect(Array(medium.prefix(4)) == [0x81, 126, 0x00, 0xC8])
        #expect(Array(long.prefix(2)) == [0x81, 127])
        #expect(long.count == 70_000 + 10)
        // Server frames are never masked (RFC 6455 §5.1, the other direction).
        #expect(medium[1] & 0x80 == 0)
    }

    // MARK: - the JSON both ways

    @Test func aCommandCarriesItsPIN() throws {
        let message = try #require(
            RemoteMessage.parse(#"{"action":"marker","pin":"0417"}"#))
        #expect(message.command == .marker)
        #expect(message.pin == "0417")
    }

    @Test func junkAndUnknownActionsAreNotCommands() {
        #expect(RemoteMessage.parse("not json") == nil)
        #expect(RemoteMessage.parse(#"{"action":"quit","pin":"1"}"#) == nil)
        #expect(RemoteMessage.parse(#"{"pin":"1"}"#) == nil)
        // A missing PIN is a message, and an empty PIN never matches.
        #expect(RemoteMessage.parse(#"{"action":"rec"}"#)?.pin == "")
    }

    /// Take names come from operator-typed fields. A quote in a project name
    /// used to be enough to break a page's parser for the rest of the shift.
    @Test func theStatusJSONSurvivesAQuoteInATakeName() throws {
        var status = RemoteStatus()
        status.takeName = #"A"001\C01"#
        status.timecode = "10:00:00:00"
        status.diskFreeGB = 412.34
        status.markerCount = 3

        let object = try #require(try JSONSerialization.jsonObject(
            with: Data(status.json.utf8)) as? [String: Any])
        #expect(object["take"] as? String == #"A"001\C01"#)
        #expect(object["tc"] as? String == "10:00:00:00")
        #expect(object["type"] as? String == "status")
        #expect(object["markers"] as? Int == 3)
        #expect((object["diskGB"] as? Double).map { abs($0 - 412.3) < 0.05 } == true)
    }

    /// An unreadable volume reports -1, and NaN is not JSON at all — a status
    /// the page cannot parse takes every other field down with it.
    @Test func anUnreadableVolumeStaysParseable() throws {
        var status = RemoteStatus()
        status.diskFreeGB = .nan
        let object = try #require(try JSONSerialization.jsonObject(
            with: Data(status.json.utf8)) as? [String: Any])
        #expect(object["diskGB"] is NSNull)
    }

    // MARK: - the PIN

    @Test func thePINIsFourDigits() {
        for _ in 0..<50 {
            let pin = RemotePIN.generate()
            let digitsOnly = pin.allSatisfy(\.isNumber)
            #expect(pin.count == 4)
            #expect(digitsOnly)
        }
    }

    @Test func onlyTheExactPINMatches() {
        #expect(RemotePIN.matches("0417", expected: "0417"))
        #expect(!RemotePIN.matches("0418", expected: "0417"))
        #expect(!RemotePIN.matches("041", expected: "0417"))
        #expect(!RemotePIN.matches("04170", expected: "0417"))
        // An app that never generated a PIN must not accept the empty string.
        #expect(!RemotePIN.matches("", expected: ""))
    }

    // MARK: - the page

    /// The page is a bundle resource with one token in it. If the token
    /// survives into the served bytes, the script throws on load and the phone
    /// shows a blank screen with no clue why.
    @Test @MainActor func thePageCarriesTheAppsLabelsAndNoLeftoverToken() throws {
        for language in [AppLanguage.english, .russian] {
            let served = ViewRender.withLanguage(language) { RemotePage.html() }
            let html = try utf8(served)
            let label = ViewRender.withLanguage(language) { L("remote_marker") }
            #expect(!html.contains(RemotePage.configToken),
                    "\(language.rawValue): the config token was not replaced")
            #expect(html.contains(label),
                    "\(language.rawValue): the page is missing its labels")
            #expect(html.contains("lang:\"\(language.rawValue)\""))
            // Self-contained: nothing is fetched from anywhere.
            #expect(!html.contains("src=\"http"))
            #expect(!html.contains("<link "))
        }
    }

    /// The page's script has to parse. Nothing else in this project can tell you
    /// that it does: it is a bundle resource with an injected config object, so a
    /// stray comma in either half compiles, ships, and shows a director a blank
    /// screen with the fault written only to a console on a phone.
    ///
    /// `new Function(source)` parses the body without running it — the script
    /// reaches for `document` and `WebSocket` on its first lines and neither
    /// exists here.
    @Test @MainActor func thePagesScriptParses() throws {
        for language in [AppLanguage.english, .russian] {
            let html = try utf8(ViewRender.withLanguage(language) {
                RemotePage.html()
            })
            let open = try #require(html.range(of: "<script>"))
            let close = try #require(html.range(of: "</script>"))
            let context = try #require(JSContext())
            context.setObject(String(html[open.upperBound..<close.lowerBound]),
                              forKeyedSubscript: "SOURCE" as NSString)
            context.evaluateScript("new Function(SOURCE)")
            #expect(context.exception == nil,
                    "\(language.rawValue): \(context.exception?.toString() ?? "")")
        }
    }

    /// Every label the script reads has to exist in both tables, or the page
    /// renders a raw key on a button the size of a phone.
    @Test @MainActor func everyPageLabelIsTranslated() {
        for (field, key) in RemotePage.labels {
            for language in [AppLanguage.english, AppLanguage.russian] {
                let value = ViewRender.withLanguage(language) { L(key) }
                #expect(value != key,
                        "\(field) renders as its raw key in \(language.rawValue)")
            }
        }
    }
}
