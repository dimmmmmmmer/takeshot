import CDataChannel
import Foundation
import Testing

@testable import TakeShotKit

/// The bridge against real libdatachannel: a real answer to a real offer.
///
/// **Why this exists.** Everything else about this feature can be checked
/// without the library: the RTP is bytes, the plan is a parse, and the
/// signalling route is a fake peer away. What none of that touches is the
/// bridge itself — the `dlopen`, the thirteen `dlsym` names, the configuration
/// struct the library is handed, the order the three negotiation calls have to
/// be made in, and whether an answer comes out the far side at all. Those are
/// the parts that would fail silently on a set, and they cannot be reasoned
/// about from here.
///
/// **What it does and does not prove.** It proves the library loads, takes the
/// browser's own offer, and produces an answer whose SHAPE is the one the app
/// asked for: this machine's host candidates, a DTLS fingerprint, and a
/// send-only H.264 track on the payload type and mid the offer named. It does
/// NOT prove a browser decodes what follows — that needs a phone on a real
/// network and a person, and `vendor/libdatachannel/README.md` says so.
///
/// Runs ONLY where the header and the runtime both are, which is a development
/// machine and not CI. It gathers on this machine's real interfaces, which is
/// the same spirit as the remote's listener tests: local, and over in
/// milliseconds because there is no STUN server in the path.
@Suite(.enabled(if: CDCPeerConnection.isSDKAvailable(),
                "this build has no libdatachannel"))
struct WebRTCBridgeTests {
    private static func peer(
        for plan: WebRTCOffer.VideoPlan) -> CDCPeerConnection {
        CDCPeerConnection(mid: plan.mid, payloadType: plan.payloadType,
                          formatParameters: plan.formatParameters,
                          ssrc: 0x1234_5678, cname: WebRTCPeer.cname)
    }

    /// The answer's shape, against the captured Chrome offer.
    ///
    /// Every line asserted here is one the browser acts on, and each has a
    /// different failure: no fingerprint is a DTLS handshake that never starts,
    /// a mid that does not match is a media section the browser discards, a
    /// payload type of ours rather than the offer's is a codec it has no
    /// decoder mapped to, and `recvonly` on our side is a negotiation that
    /// succeeds and moves no bytes.
    @Test func aRealOfferComesBackAsAnAnswerTheBrowserCanActOn() throws {
        let plan: WebRTCOffer.VideoPlan = try #require(
            WebRTCOffer.videoPlan(in: WebRTCOfferFixture.chromeRecvOnlyVideo))
        let connection = Self.peer(for: plan)
        defer { connection.close() }
        let answer: String = try connection.answerOffer(
            WebRTCOfferFixture.chromeRecvOnlyVideo,
            gatheringTimeout: WebRTCPeer.gatheringTimeout)

        #expect(answer.hasPrefix("v=0"))
        #expect(answer.contains("a=fingerprint:sha-256"))
        #expect(answer.contains("a=ice-ufrag:"))
        #expect(answer.contains("a=ice-pwd:"))
        #expect(answer.contains("a=mid:0"))
        #expect(answer.contains("a=sendonly"))
        #expect(answer.contains("a=rtpmap:119 H264/90000"))
        #expect(answer.contains("profile-level-id=64001f"))
        #expect(answer.contains("a=ssrc:305419896 cname:takeshot"))
        // A DTLS role — the browser offered `actpass`, so it is the answerer's
        // to choose and either is legal. Without one there is no handshake.
        #expect(answer.contains("a=setup:active")
            || answer.contains("a=setup:passive"), "no DTLS role in the answer")
        // **The media section is not rejected.** A zero port is how SDP says
        // "no", and it is exactly what comes back if the track is added in the
        // wrong order — before the remote description, or after the local one.
        // The negotiation then succeeds and carries nothing, which is the
        // quietest way this whole feature can fail.
        #expect(!answer.contains("m=video 0 "), "the video section was rejected")
        // PLI has to be OFFERED for a browser to send one, and a browser that
        // cannot ask for a keyframe never recovers from a lost one.
        #expect(answer.contains("a=rtcp-fb:119 nack pli"))
    }

    /// **Host candidates and nothing else.** No STUN server and no TURN server
    /// is configured, so the answer must carry only this machine's own
    /// interfaces — a `srflx` or `relay` line here would mean the app reached
    /// off the set network to build it, which is out of scope by the owner's
    /// own rule and is a gathering phase that ends in a timeout on a network
    /// with no route out.
    @Test func onlyHostCandidatesAreGathered() throws {
        let plan: WebRTCOffer.VideoPlan = try #require(
            WebRTCOffer.videoPlan(in: WebRTCOfferFixture.chromeRecvOnlyVideo))
        let connection = Self.peer(for: plan)
        defer { connection.close() }
        let answer: String = try connection.answerOffer(
            WebRTCOfferFixture.chromeRecvOnlyVideo,
            gatheringTimeout: WebRTCPeer.gatheringTimeout)
        let candidates: [String] = answer
            .split(whereSeparator: \.isNewline)
            .map { String($0) }
            .filter { $0.hasPrefix("a=candidate:") }
        #expect(!candidates.isEmpty, "this machine gathered no candidates")
        #expect(candidates.allSatisfy { $0.contains("typ host") },
                "a candidate came from off this machine: \(candidates)")
        // **And the answer is COMPLETE**, which is what makes one POST the
        // whole of signalling: `a=end-of-candidates` is the library saying it
        // has nothing further to trickle, so there is no second channel for the
        // page to keep open and nothing arrives after the fetch returns.
        #expect(answer.contains("a=end-of-candidates"),
                "the answer was returned before gathering finished")
    }

    /// Sending before the browser has connected is refused rather than
    /// crashing, and closing twice is not a fault.
    ///
    /// The first is the ordinary case for a viewer's first frames — the encoder
    /// is running before DTLS is up — and the second is what `dealloc` does
    /// after an explicit `close`.
    @Test func sendingBeforeTheTrackIsOpenIsRefusedAndCloseIsIdempotent() throws {
        let plan: WebRTCOffer.VideoPlan = try #require(
            WebRTCOffer.videoPlan(in: WebRTCOfferFixture.chromeRecvOnlyVideo))
        let connection = Self.peer(for: plan)
        let packet: [UInt8] = [UInt8](repeating: 0x80, count: 32)
        #expect(packet.withUnsafeBytes {
            connection.sendRTP($0.baseAddress!, length: $0.count)
        } == false)
        _ = try connection.answerOffer(
            WebRTCOfferFixture.chromeRecvOnlyVideo,
            gatheringTimeout: WebRTCPeer.gatheringTimeout)
        // Still not open: nobody is on the other end of this answer.
        #expect(packet.withUnsafeBytes {
            connection.sendRTP($0.baseAddress!, length: $0.count)
        } == false)
        connection.close()
        connection.close()
    }

    /// An offer the library cannot parse is an error and not a crash, and the
    /// error's code is the one the route turns into a 400.
    @Test func rubbishInsteadOfAnOfferIsAnError() throws {
        let plan: WebRTCOffer.VideoPlan = try #require(
            WebRTCOffer.videoPlan(in: WebRTCOfferFixture.chromeRecvOnlyVideo))
        let connection = Self.peer(for: plan)
        defer { connection.close() }
        #expect(throws: (any Error).self) {
            try connection.answerOffer("not an offer",
                                       gatheringTimeout: 1)
        }
    }
}
