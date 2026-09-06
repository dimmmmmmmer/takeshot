import Foundation
import Testing

@testable import TakeShotKit

/// The JPEG grid lived at `/cameras` and crew phones bookmarked it. The page
/// was retired for the live picture; the bookmark got a bare text 404.
struct RemoteRedirectTests {
    @Test func theRetiredGridAddressSendsThePhoneToTheLivePage() throws {
        let response = try #require(String(data: RemoteResponse.redirect(
            to: RemotePage.livePath), encoding: .utf8))
        #expect(response.hasPrefix("HTTP/1.1 302 Found\r\n"), "\(response)")
        #expect(response.contains("Location: \(RemotePage.livePath)\r\n"), "\(response)")
    }

    /// The router itself names the old address — a redirect nothing routes to
    /// is a redirect nobody gets.
    @Test func theRouterKnowsTheOldAddress() throws {
        let source = try String(contentsOfFile: #filePath
            .replacingOccurrences(of: "Tests/TakeShotKitTests/RemoteRedirectTests.swift",
                                  with: "Sources/TakeShotKit/RemoteClient+Reading.swift"),
            encoding: .utf8)
        #expect(source.contains("case \"/cameras\":"),
                "the GET router has no case for the retired grid address")
        #expect(source.contains("RemoteResponse.redirect(to: RemotePage.livePath)"))
    }
}
