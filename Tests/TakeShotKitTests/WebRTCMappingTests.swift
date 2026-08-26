import CDataChannel
import Foundation
import Testing

@testable import TakeShotKit

/// The two translations between the bridge and the app, and what each of them
/// decides.
///
/// Both are pure and both are checkable on a build with no libdatachannel in
/// it, because the enums are the HEADER's rather than the runtime's — which is
/// most of why they exist as separate types at all. A wrong entry in either is
/// silent: a state mapped to the wrong case is a viewer that holds its slot
/// forever or one dropped while it was working, and a failure code mapped to
/// the wrong response is a page told to give up over an offer it could simply
/// have made differently.
@Suite struct WebRTCMappingTests {
    /// Every state the library reports, and the one question the app asks of
    /// it: is this connection over?
    ///
    /// `disconnected` is the entry that matters. It looks like a failure and is
    /// not one — a phone that went behind a truck comes back — and treating it
    /// as over would drop the viewer's slot and its picture on every wobble in
    /// the set's Wi-Fi.
    @Test func onlyFailedAndClosedEndAViewer() {
        #expect(WebRTCPeer.state(.new) == .new)
        #expect(WebRTCPeer.state(.connecting) == .connecting)
        #expect(WebRTCPeer.state(.connected) == .connected)
        #expect(WebRTCPeer.state(.disconnected) == .disconnected)
        #expect(WebRTCPeer.state(.failed) == .failed)
        #expect(WebRTCPeer.state(.closed) == .closed)

        let over: [WebRTCPeerState] = [.new, .connecting, .connected,
                                       .disconnected, .failed, .closed]
            .filter(\.isOver)
        #expect(over == [.failed, .closed])
    }

    /// The bridge's failure code IS the classification, and each one asks for a
    /// different answer from the signalling route.
    @Test func theFailureCodeDecidesWhatTheRouteAnswers() {
        let domain = "com.takeshot.cdatachannel"
        func error(_ code: CDCAnswerFailure, _ text: String) -> NSError {
            NSError(domain: domain, code: code.rawValue,
                    userInfo: [NSLocalizedDescriptionKey: text])
        }
        #expect(WebRTCPeer.classify(error(.unavailable, "no library"))
            == .unavailable("no library"))
        #expect(WebRTCPeer.classify(error(.offer, "bad offer"))
            == .offer("bad offer"))
        #expect(WebRTCPeer.classify(error(.runtime, "no interfaces"))
            == .runtime("no interfaces"))
        // A code from nowhere is a runtime failure rather than a crash or a
        // silent success — the library gained an error this app has not met.
        #expect(WebRTCPeer.classify(NSError(domain: domain, code: 99))
            == .runtime(NSError(domain: domain, code: 99).localizedDescription))
    }

    /// And what each classification becomes on the wire.
    ///
    /// The split is the whole point: only a bad OFFER is a 400, because only a
    /// bad offer can be answered by offering differently. Everything else is a
    /// 503 — the page says why and stops, which is what a build with no library
    /// in it needs it to do.
    @Test func onlyABadOfferIsSomethingThePageCanFix() {
        #expect(CaptureController.refusal(.offer("no video")) == .rejected)
        #expect(CaptureController.refusal(.unavailable("install it"))
            == .unavailable("install it"))
        #expect(CaptureController.refusal(.runtime("no interfaces"))
            == .unavailable("no interfaces"))
    }

    /// The offer body's shape, on its own: two string fields and nothing else
    /// accepted.
    ///
    /// Strict about both being strings, and that is not pedantry — a body with
    /// a number where the PIN should be must not be read as an empty code and
    /// charged to the tarpit as a guess.
    @Test func onlyTwoStringFieldsAreAnOffer() throws {
        let good = try #require(RemoteWebRTC.parse(
            Data(#"{"pin":"1234","sdp":"v=0\r\n"}"#.utf8)))
        #expect(good.pin == "1234")
        #expect(good.sdp == "v=0\r\n")
        #expect(RemoteWebRTC.parse(Data("{}".utf8)) == nil)
        #expect(RemoteWebRTC.parse(Data(#"{"pin":1234,"sdp":"v=0"}"#.utf8)) == nil)
        #expect(RemoteWebRTC.parse(Data(#"{"pin":"1","sdp":""}"#.utf8)) == nil)
        #expect(RemoteWebRTC.parse(Data(#"["pin","sdp"]"#.utf8)) == nil)
        #expect(RemoteWebRTC.parse(Data()) == nil)
    }
}
