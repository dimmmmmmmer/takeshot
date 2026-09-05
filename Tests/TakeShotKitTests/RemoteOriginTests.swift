import Foundation
import Testing

@testable import TakeShotKit

/// The two headers a browser sends that the remote now reads: `Origin` on an
/// upgrade, and the framing policy on every page.
@Suite struct RemoteOriginTests {
    /// **An upgrade from a page served elsewhere is refused.** A browser sends
    /// `Origin` on every WebSocket upgrade and nothing read it, so any web page
    /// open on a crew phone could drive the remote through that phone's
    /// session. No `Origin` is a non-browser client and is left alone.
    @Test func aForeignOriginIsRefusedAndOurOwnIsNot() throws {
        func request(origin: String?) throws -> RemoteRequest {
            var text = "GET /ws HTTP/1.1\r\nHost: 192.168.1.5:8765\r\n"
            if let origin { text += "Origin: \(origin)\r\n" }
            text += "Upgrade: WebSocket\r\nConnection: Upgrade\r\n"
            text += "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
            let head = Data(text.utf8)
            let end = try #require(RemoteRequest.headEnd(in: head))
            return try #require(RemoteRequest.parse(Data(head[..<end])))
        }
        #expect(!(try request(origin: nil)).isFromForeignOrigin, "a script was refused")
        #expect(!(try request(origin: "http://192.168.1.5:8765")).isFromForeignOrigin,
                "the page this server served was refused")
        #expect((try request(origin: "http://evil.example")).isFromForeignOrigin,
                "a page from another site was let through")
        #expect((try request(origin: "null")).isFromForeignOrigin)
    }

    /// And the pages cannot be framed.
    @Test func thePagesRefuseToBeFramed() {
        let head = String(data: RemoteResponse.page(Data("<p>x</p>".utf8)).prefix(2000),
                          encoding: .utf8) ?? ""
        #expect(head.contains("frame-ancestors 'none'"), "no frame-ancestors in the CSP")
        #expect(head.contains("X-Frame-Options: DENY"))
    }
}
