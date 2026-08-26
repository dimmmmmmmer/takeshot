import CaptureCore
import Foundation
import JavaScriptCore
import Testing

@testable import TakeShotKit

/// The `/live` page's own half of the choice: it offers all three pictures, it
/// remembers what this phone picked, and the words it puts on the wire are the
/// app's own.
///
/// **What this can and cannot check.** Everything below is the page as SERVED —
/// the markup, the injected config, and that the script parses. What no test
/// here can reach is a real `RTCPeerConnection`: whether the picture actually
/// changes on screen without a stall needs a browser and a Mac with the library
/// on it, and it is listed as unverified rather than implied by these passing.
@MainActor
struct RemoteLivePageTests {
    private func utf8(_ data: Data) throws -> String {
        try #require(String(bytes: data, encoding: .utf8))
    }

    /// **The wire words come from the app, in both languages.**
    ///
    /// A page with its own spelling of a picture name is a 400 nobody can see
    /// from a handset, so the list is injected rather than typed — and the
    /// order is the enum's, which is the order the buttons sit in.
    @Test func thePageIsGivenThePicturesTheAppActuallyHas() throws {
        for language in [AppLanguage.english, .russian] {
            let html = try utf8(ViewRender.withLanguage(language) {
                RemotePage.liveHTML()
            })
            let names = LivePicture.allCases
                .map { RemoteJSON.quoted($0.rawValue) }
                .joined(separator: ",")
            #expect(html.contains("pictures:[\(names)]"),
                    "\(language.rawValue): the page's picture list is not the app's")
            #expect(html.contains("picturePath:\(RemoteJSON.quoted(RemoteWebRTC.picturePath))"))
            #expect(html.contains("viewerHeader:\(RemoteJSON.quoted(RemoteWebRTC.viewerHeader))"))
        }
    }

    /// Every picture has a label, in both languages, and no two of them are the
    /// same word — a switch whose segments read alike is a switch nobody can
    /// use in a hurry.
    @Test func everyPictureIsLabelledInBothLanguages() throws {
        for language in [AppLanguage.english, .russian] {
            let labels: [String] = ViewRender.withLanguage(language) {
                LivePicture.allCases.map { L("live_picture_\($0.rawValue)") }
            }
            for (picture, label) in zip(LivePicture.allCases, labels) {
                #expect(label != "live_picture_\(picture.rawValue)",
                        "\(language.rawValue): \(picture) has no label")
            }
            #expect(Set(labels).count == labels.count,
                    "\(language.rawValue): two pictures share a label: \(labels)")
            let html = try utf8(ViewRender.withLanguage(language) {
                RemotePage.liveHTML()
            })
            for (picture, label) in zip(LivePicture.allCases, labels) {
                let field = RemotePage.pictureField(for: picture)
                #expect(html.contains("\(field):\(RemoteJSON.quoted(label))"),
                        "\(language.rawValue): \(picture)'s label is not on the page")
            }
        }
    }

    /// The behaviours the choice rests on, pinned against the markup — a rename
    /// on either side of these would otherwise fail only on a phone.
    @Test func theLivePageKeepsItsContracts() throws {
        let html = try utf8(RemotePage.liveHTML())
        // The offer names the picture, so the first frame is already the right
        // one rather than a second's worth of the wrong one.
        #expect(html.contains("picture: picture"),
                "the offer no longer carries the page's choice")
        // The choice is remembered per PHONE, which is what makes two people on
        // one app able to watch two things.
        #expect(html.contains("localStorage.setItem(PICTURE_KEY"),
                "the choice is no longer remembered")
        // A stored name this build does not have falls back rather than being
        // offered — the app would refuse it and the page would look broken.
        #expect(html.contains("CFG.pictures.indexOf(stored) >= 0"),
                "a stale stored picture is no longer checked")
        // The change goes to the change route while a connection exists, and
        // falls back to a re-offer when the app no longer knows this viewer.
        #expect(html.contains("fetch(CFG.picturePath"),
                "the page no longer changes picture without re-offering")
        #expect(html.contains("if (!response.ok && picture === asked) { dropped(); }"),
                "a refused change no longer falls back to offering again")
        // The id is read off the header, which is what makes the body still the
        // bare SDP the page hands to setRemoteDescription.
        #expect(html.contains("response.headers.get(CFG.viewerHeader)"))
    }

    /// The script has to parse, in both languages — it is a bundle resource
    /// with an injected config object, and a stray comma in either half
    /// compiles, ships, and shows a director a blank screen.
    @Test func theLivePagesScriptParses() throws {
        for language in [AppLanguage.english, .russian] {
            let html = try utf8(ViewRender.withLanguage(language) {
                RemotePage.liveHTML()
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

    /// The page still loads nothing from anywhere: the picture switch is markup
    /// the script builds, not a control fetched from a CDN.
    @Test func thePageStillFetchesNothing() throws {
        let html = try utf8(RemotePage.liveHTML())
        #expect(!html.contains("src=\"http"))
        #expect(!html.contains("<link "))
        #expect(!html.contains(RemotePage.configToken))
    }
}
