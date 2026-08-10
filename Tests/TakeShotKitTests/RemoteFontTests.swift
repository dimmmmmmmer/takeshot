import Foundation
import Testing

@testable import TakeShotKit

/// The web font the three pages are served with.
///
/// The pages name the app's own face first and always did, but the bytes were
/// not shipped — so a phone on set rendered in the system face and only the
/// operator's Mac, which has the font installed, ever showed the real one. The
/// owner holds a licence that covers embedding it, so the face now travels
/// inside the page.
///
/// What is held here is what a set network cannot forgive: the resource has to
/// be in the BUNDLE (a build on CI or on anyone else's machine must produce the
/// same pages as this developer's, whose ~/Library/Fonts is not part of the
/// repository), the pages have to reference it, and the fallback stack has to
/// stay behind it.
@Suite @MainActor struct RemoteFontTests {
    private func utf8(_ data: Data) throws -> String {
        try #require(String(bytes: data, encoding: .utf8))
    }

    private func pages() -> [(name: String, data: Data)] {
        [("remote", RemotePage.html()), ("script", RemotePage.scriptHTML()),
         ("cameras", RemotePage.camerasHTML()),
         ("slate", RemotePage.slateHTML())]
    }

    /// The font is a package resource, not a file in the developer's font
    /// folder — and it is a real WOFF2, not an .otf that has been renamed.
    @Test func theFontShipsInTheBundle() throws {
        for face in RemotePage.fontFaces {
            let url = try #require(
                Bundle.module.url(forResource: face.resource,
                                  withExtension: "woff2"),
                "\(face.resource).woff2 is not in the bundle")
            let data = try Data(contentsOf: url)
            #expect(data.prefix(4).elementsEqual(Array("wOF2".utf8)),
                    "\(face.resource) is not WOFF2: \(Array(data.prefix(4)))")
            // the licensed original is ~117 KB; a face that came back the same
            // size is one that was copied rather than converted
            #expect(data.count < 80_000,
                    "\(face.resource) is \(data.count) bytes")
        }
    }

    /// Two weights, and only two: the family has fourteen and every one of them
    /// would be paid for on every page load over a set Wi-Fi network. 400 for
    /// text, 700 for the buttons and labels; the 600 and 800 the pages ask for
    /// snap onto the bold.
    @Test func onlyTheTwoWeightsThePagesUseAreEmbedded() throws {
        #expect(RemotePage.fontFaces.count == 2)
        #expect(RemotePage.fontFaces.map(\.weight) == [400, 700])
        let css = RemotePage.fontCSS
        #expect(!css.isEmpty, "no @font-face was built at all")
        #expect(css.components(separatedBy: "@font-face").count == 3)
        #expect(css.contains("format(\"woff2\")"))
        #expect(css.contains("font-display:swap"),
                "a page that blocks on a 145 KB data URI shows nothing at all")
    }

    /// Every page carries the face, in the family the stylesheet names, with the
    /// bytes in it — and no page is left holding the raw token.
    @Test func everyPageCarriesTheEmbeddedFace() throws {
        for page in pages() {
            let html = try utf8(page.data)
            #expect(!html.contains(RemotePage.fontToken),
                    "\(page.name) still holds the font token")
            #expect(html.contains("@font-face"), "\(page.name) has no face")
            #expect(html.contains("font-family:\"\(RemotePage.fontFamily)\""),
                    "\(page.name) embeds a face it never names")
            #expect(html.contains("data:font/woff2;base64,"),
                    "\(page.name) references the font instead of carrying it")
            // …and the system stack is still behind it: a browser that refuses
            // the face, or a build served without the resource, must fall
            // through to the platform font rather than to nothing
            #expect(html.contains("\"\(RemotePage.fontFamily)\", -apple-system"),
                    "\(page.name) lost its fallback stack")
        }
    }

    /// The whole page has to stay something a phone can pull over set Wi-Fi:
    /// the two faces are ~145 KB of base64 between them, and that is the budget
    /// this test defends — a third weight, or the .otf originals instead of the
    /// WOFF2, doubles it.
    @Test func thePagesStayWithinTheirWeightBudget() throws {
        for page in pages() {
            #expect(page.data.count < 250_000,
                    "\(page.name) is \(page.data.count) bytes")
            // and the font really is the bulk of it — if this stops being true
            // the number above is measuring something else
            #expect(page.data.count > RemotePage.fontCSS.count)
        }
    }

    /// What is in the page decodes back to the file that shipped. A data URI
    /// that is one character short is a face the browser silently refuses, and
    /// the page then looks exactly like the fallback it is supposed to be
    /// standing in front of.
    @Test func theEmbeddedBytesDecodeBackToTheShippedFont() throws {
        let html = try utf8(RemotePage.html())
        let marker = "data:font/woff2;base64,"
        let start = try #require(html.range(of: marker))
        let rest = html[start.upperBound...]
        let end = try #require(rest.firstIndex(of: ")"))
        let decoded = try #require(Data(base64Encoded: String(rest[..<end])),
                                   "the payload is not valid base64")
        let url = try #require(Bundle.module.url(
            forResource: RemotePage.fontFaces[0].resource,
            withExtension: "woff2"))
        #expect(decoded == (try Data(contentsOf: url)),
                "the page carries \(decoded.count) bytes of something else")
    }
}
