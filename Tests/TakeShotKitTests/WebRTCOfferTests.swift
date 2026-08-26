import Foundation
import Testing

@testable import TakeShotKit

/// The app's half of the answer, against the browser offer it has to answer.
///
/// **What this covers and what it cannot.** libdatachannel writes the answer
/// SDP — the ICE credentials, the host candidates, the DTLS fingerprint — and
/// none of that is checkable from here or belongs to this app. What IS this
/// app's is everything about the PICTURE: which of the browser's ten H.264
/// payload types to answer with, which media section it lives in, and whether
/// there is anything answerable at all. Those three fields are exactly what
/// `rtcAddTrackEx` is handed, so a mistake in them is an answer that negotiates
/// perfectly and carries a codec the browser cannot decode — which looks, from
/// a phone, identical to a network fault.
@Suite struct WebRTCAnswerPlanTests {
    /// The pick, out of a real Chrome offer: mid 0, payload type 119, and the
    /// fmtp echoed back as it arrived.
    ///
    /// 119 and not the first H.264 in the list, and that is the whole decision:
    /// Chrome offers 103 first (Constrained Baseline) and 119 is the High
    /// profile one, which is what `SRTVideoEncoder` actually produces. Answering
    /// 103 would describe a stream that is not the stream.
    @Test func theHighProfilePayloadTypeIsTheOneAnswered() throws {
        let plan: WebRTCOffer.VideoPlan = try #require(
            WebRTCOffer.videoPlan(in: WebRTCOfferFixture.chromeRecvOnlyVideo))
        #expect(plan.mid == "0")
        #expect(plan.payloadType == 119)
        #expect(plan.formatParameters
            == "level-asymmetry-allowed=1;packetization-mode=1;"
                + "profile-level-id=64001f")
    }

    /// Every H.264 payload type in the offer is seen, and nothing else is.
    ///
    /// The list is what the choice is made from, so it is worth pinning apart
    /// from the choice: an rtpmap walk that swallowed the RTX entries (which
    /// share the 90 kHz clock rate and sit right beside each H.264 line) would
    /// still answer 119 today and answer an RTX payload type the day Chrome
    /// reorders its list.
    @Test func onlyTheH264PayloadTypesAreCollected() throws {
        let section: WebRTCOffer.VideoSection = try #require(
            WebRTCOffer.videoSection(in: WebRTCOfferFixture.chromeRecvOnlyVideo))
        #expect(section.h264.map(\.payloadType)
            == [39, 41, 43, 103, 107, 109, 115, 117, 119, 121])
        #expect(section.mid == "0")
        #expect(section.wantsToReceive)
    }

    /// An offer whose H.264 is all `packetization-mode=0` is refused.
    ///
    /// Mode 0 allows single NAL unit packets and nothing else, so a slice past
    /// the MTU cannot be sent — and at 1080p every keyframe is. Answering it
    /// anyway and then fragmenting is a black rectangle with no error anywhere,
    /// which is the failure this refusal exists to make loud.
    @Test func anOfferWithNoFragmentableH264IsRefused() {
        #expect(WebRTCOffer.videoPlan(
            in: WebRTCOfferFixture.chromeSingleNALOnly) == nil)
    }

    /// A browser offering to SEND is refused. This app is an output; there is
    /// nothing here that could receive a picture, and answering `sendonly` with
    /// `sendonly` is a negotiation that succeeds and moves no bytes.
    @Test func anOfferThatWillNotReceiveIsRefused() {
        #expect(WebRTCOffer.videoPlan(
            in: WebRTCOfferFixture.chromeSendOnlyVideo) == nil)
    }

    /// Text that is not an offer, an offer with no video in it, and an offer
    /// whose video section has no mid: three shapes, one refusal, and none of
    /// them a crash.
    @Test func anythingThatIsNotAnAnswerableOfferIsRefused() {
        #expect(WebRTCOffer.videoPlan(in: "") == nil)
        #expect(WebRTCOffer.videoPlan(in: "hello") == nil)
        #expect(WebRTCOffer.videoPlan(in: "v=0\r\nm=audio 9 RTP/AVP 0\r\n")
            == nil)
        let noMid = WebRTCOfferFixture.chromeRecvOnlyVideo
            .replacingOccurrences(of: "a=mid:0", with: "a=x-mid:0")
        #expect(WebRTCOffer.videoPlan(in: noMid) == nil)
    }

    /// The mid is the OFFER's, whatever it is called. Browsers number them and
    /// an application may name them; an answer whose mid does not match the
    /// offer's is an answer to a question nobody asked, and the browser drops
    /// the whole media section.
    @Test func theMidIsWhateverTheOfferCalledIt() throws {
        let named = WebRTCOfferFixture.chromeRecvOnlyVideo
            .replacingOccurrences(of: "a=mid:0", with: "a=mid:viewer")
        let plan: WebRTCOffer.VideoPlan = try #require(
            WebRTCOffer.videoPlan(in: named))
        #expect(plan.mid == "viewer")
    }
}

/// The ranking the pick is made with, on its own.
@Suite struct WebRTCProfileRankTests {
    /// High first, then Main, then Baseline, and anything else last.
    ///
    /// Last and not refused: a profile nobody here recognises is still H.264,
    /// and an H.264 decoder accepts a higher profile than it advertised far
    /// more reliably than a director accepts a black rectangle. The order is
    /// the encoder's own output first (`kVTProfileLevel_H264_High_AutoLevel`),
    /// which is the only one that describes the stream exactly.
    @Test func theRankingLeadsWithTheProfileTheEncoderProduces() {
        let high = WebRTCOffer.rank(of: "profile-level-id=64001f")
        let main = WebRTCOffer.rank(of: "profile-level-id=4d001f")
        let base = WebRTCOffer.rank(of: "profile-level-id=42e01f")
        let other = WebRTCOffer.rank(of: "profile-level-id=f4001f")
        #expect(high < main)
        #expect(main < base)
        #expect(base < other)
        // And so does a payload type that stated no profile at all.
        #expect(WebRTCOffer.rank(of: "packetization-mode=1") == other)
    }

    /// A `profile-level-id` that is not six hex digits is read as absent rather
    /// than half-parsed. An offer is a stranger's text, and a profile guessed
    /// from three characters would sort a codec above one that said what it is.
    @Test func aMalformedProfileIsReadAsNoProfile() {
        #expect(WebRTCOffer.profileIDC(in: "profile-level-id=64001f") == 0x64)
        #expect(WebRTCOffer.profileIDC(in: "profile-level-id=640") == nil)
        #expect(WebRTCOffer.profileIDC(in: "profile-level-id=zzzzzz") == nil)
        #expect(WebRTCOffer.profileIDC(in: "packetization-mode=1") == nil)
        // Spaces around the `=` are legal in fmtp and appear in the wild.
        #expect(WebRTCOffer.profileIDC(in: "x=1; profile-level-id = 4d001f ")
            == 0x4D)
    }

    /// Two payload types at the same rank are settled by the lower number, so
    /// the pick cannot depend on dictionary ordering. Without it this suite
    /// would pass or fail per run on an offer that listed High twice.
    @Test func aTieIsBrokenByTheLowerPayloadType() throws {
        let twice = WebRTCOfferFixture.chromeRecvOnlyVideo
            .replacingOccurrences(of: "profile-level-id=4d001f",
                                  with: "profile-level-id=64001f")
        let plan: WebRTCOffer.VideoPlan = try #require(
            WebRTCOffer.videoPlan(in: twice))
        // 117 is Chrome's Main-profile mode-1 entry, now claiming High: it is
        // the lower number, so it wins over 119.
        #expect(plan.payloadType == 117)
    }
}
