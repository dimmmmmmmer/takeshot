import Foundation

/// A real browser offer, captured rather than composed.
///
/// This is what Chrome's `createOffer` produced for
/// `addTransceiver('video', {direction: 'recvonly'})` with no ICE servers
/// configured — the exact call `live.html` makes — copied out of
/// `pc.localDescription.sdp`. Nothing is edited: the only change is that lines
/// past this project's column limit are broken with a Swift line continuation,
/// which the literal puts back together byte for byte.
///
/// **Captured rather than generated, because generating it is the thing being
/// checked.** An offer this suite built itself would agree with the parser by
/// construction — it would carry the payload types the parser expects, in the
/// order it expects, spelled the way it spells them. What makes this fixture
/// worth anything is that nothing in `Sources` had any say in it, including
/// the awkward parts, and the awkward parts are the ones that matter: ten
/// H.264 payload types rather than one, five of them offered with
/// `packetization-mode=0` (which this app cannot send at all), the profiles in
/// no useful order, and every RTX, RED, FEC and `rtcp-fb` line in between to
/// be stepped over.
///
/// Two facts in it are worth naming because they cost real behaviour:
///
/// - **The candidates are mDNS names, not addresses.** Chrome replaces host
///   IPs with `<uuid>.local` for privacy, and the far end has to resolve them.
///   On macOS `getaddrinfo` does that through mDNSResponder, so libjuice can —
///   but it is a resolution step that has never run in this suite, and it is
///   the first thing to look at if a phone gathers and never connects.
/// - **`a=ice-options:trickle`** is offered and this app does not trickle.
///   That is legal: trickle is an offer to send more candidates later, not a
///   demand that the answerer do the same, and the page waits for its own
///   gathering to finish before it POSTs — so every candidate either end has
///   is already in the one exchange.
enum WebRTCOfferFixture {
    /// The captured offer, with SDP's own CRLF line endings restored — the
    /// literal below holds LF, and a parser that worked on only one of the two
    /// would pass here and fail on the wire.
    static var chromeRecvOnlyVideo: String {
        captured.split(separator: "\n", omittingEmptySubsequences: false)
            .joined(separator: "\r\n")
    }

    /// The same offer with its video section's direction flipped: a browser
    /// offering to SEND video to this app. Nothing here answers that — the app
    /// is an output — and the flip is one line, so it is made from the real
    /// fixture rather than written out again.
    static var chromeSendOnlyVideo: String {
        chromeRecvOnlyVideo.replacingOccurrences(of: "a=recvonly",
                                                 with: "a=sendonly")
    }

    /// And with every `packetization-mode=1` turned into mode 0: an offer whose
    /// H.264 cannot be fragmented, which is a picture this app cannot send even
    /// though every other field lines up.
    static var chromeSingleNALOnly: String {
        chromeRecvOnlyVideo.replacingOccurrences(of: "packetization-mode=1",
                                                 with: "packetization-mode=0")
    }

    private static let captured = """
v=0
o=- 3835526050707243603 2 IN IP4 127.0.0.1
s=-
t=0 0
a=group:BUNDLE 0
a=extmap-allow-mixed
a=msid-semantic: WMS
m=video 9 UDP/TLS/RTP/SAVPF 96 97 98 99 100 101 35 36 37 38 103 104 107 108 \
109 114 115 116 117 118 39 40 41 42 43 44 45 46 47 48 119 120 121 122 49 50 \
51 52 123 124 125 53
c=IN IP4 0.0.0.0
a=rtcp:9 IN IP4 0.0.0.0
a=candidate:3052377920 1 udp 2113937151 \
39dfec2c-0d92-4d4e-b85e-10abf7063bbe.local 65181 typ host generation 0 \
network-cost 999
a=candidate:48165513 1 udp 2113942271 \
6988c9f2-ee62-4d0e-a082-b4b9df176881.local 53326 typ host generation 0 \
network-cost 999
a=ice-ufrag:STJI
a=ice-pwd:7i9MfND1+Jo5QrIhuIKFLnsr
a=ice-options:trickle
a=fingerprint:sha-256 F6:52:71:48:F1:B1:CC:D5:EB:C3:68:F1:6A:5C:8E:40:AC:8D:\
3A:A3:48:30:F1:5E:28:90:0D:EF:E2:43:0D:AB
a=setup:actpass
a=mid:0
a=extmap:1 urn:ietf:params:rtp-hdrext:toffset
a=extmap:2 http://www.webrtc.org/experiments/rtp-hdrext/abs-send-time
a=extmap:3 urn:3gpp:video-orientation
a=extmap:4 \
http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01
a=extmap:5 http://www.webrtc.org/experiments/rtp-hdrext/playout-delay
a=extmap:6 http://www.webrtc.org/experiments/rtp-hdrext/video-content-type
a=extmap:7 http://www.webrtc.org/experiments/rtp-hdrext/video-timing
a=extmap:8 http://www.webrtc.org/experiments/rtp-hdrext/color-space
a=extmap:9 urn:ietf:params:rtp-hdrext:sdes:mid
a=extmap:10 urn:ietf:params:rtp-hdrext:sdes:rtp-stream-id
a=extmap:11 urn:ietf:params:rtp-hdrext:sdes:repaired-rtp-stream-id
a=recvonly
a=rtcp-mux
a=rtcp-rsize
a=rtpmap:96 VP8/90000
a=rtcp-fb:96 goog-remb
a=rtcp-fb:96 transport-cc
a=rtcp-fb:96 ccm fir
a=rtcp-fb:96 nack
a=rtcp-fb:96 nack pli
a=rtpmap:97 rtx/90000
a=fmtp:97 apt=96
a=rtpmap:98 VP9/90000
a=rtcp-fb:98 goog-remb
a=rtcp-fb:98 transport-cc
a=rtcp-fb:98 ccm fir
a=rtcp-fb:98 nack
a=rtcp-fb:98 nack pli
a=fmtp:98 profile-id=0
a=rtpmap:99 rtx/90000
a=fmtp:99 apt=98
a=rtpmap:100 VP9/90000
a=rtcp-fb:100 goog-remb
a=rtcp-fb:100 transport-cc
a=rtcp-fb:100 ccm fir
a=rtcp-fb:100 nack
a=rtcp-fb:100 nack pli
a=fmtp:100 profile-id=2
a=rtpmap:101 rtx/90000
a=fmtp:101 apt=100
a=rtpmap:35 VP9/90000
a=rtcp-fb:35 goog-remb
a=rtcp-fb:35 transport-cc
a=rtcp-fb:35 ccm fir
a=rtcp-fb:35 nack
a=rtcp-fb:35 nack pli
a=fmtp:35 profile-id=1
a=rtpmap:36 rtx/90000
a=fmtp:36 apt=35
a=rtpmap:37 VP9/90000
a=rtcp-fb:37 goog-remb
a=rtcp-fb:37 transport-cc
a=rtcp-fb:37 ccm fir
a=rtcp-fb:37 nack
a=rtcp-fb:37 nack pli
a=fmtp:37 profile-id=3
a=rtpmap:38 rtx/90000
a=fmtp:38 apt=37
a=rtpmap:103 H264/90000
a=rtcp-fb:103 goog-remb
a=rtcp-fb:103 transport-cc
a=rtcp-fb:103 ccm fir
a=rtcp-fb:103 nack
a=rtcp-fb:103 nack pli
a=fmtp:103 \
level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42001f
a=rtpmap:104 rtx/90000
a=fmtp:104 apt=103
a=rtpmap:107 H264/90000
a=rtcp-fb:107 goog-remb
a=rtcp-fb:107 transport-cc
a=rtcp-fb:107 ccm fir
a=rtcp-fb:107 nack
a=rtcp-fb:107 nack pli
a=fmtp:107 \
level-asymmetry-allowed=1;packetization-mode=0;profile-level-id=42001f
a=rtpmap:108 rtx/90000
a=fmtp:108 apt=107
a=rtpmap:109 H264/90000
a=rtcp-fb:109 goog-remb
a=rtcp-fb:109 transport-cc
a=rtcp-fb:109 ccm fir
a=rtcp-fb:109 nack
a=rtcp-fb:109 nack pli
a=fmtp:109 \
level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f
a=rtpmap:114 rtx/90000
a=fmtp:114 apt=109
a=rtpmap:115 H264/90000
a=rtcp-fb:115 goog-remb
a=rtcp-fb:115 transport-cc
a=rtcp-fb:115 ccm fir
a=rtcp-fb:115 nack
a=rtcp-fb:115 nack pli
a=fmtp:115 \
level-asymmetry-allowed=1;packetization-mode=0;profile-level-id=42e01f
a=rtpmap:116 rtx/90000
a=fmtp:116 apt=115
a=rtpmap:117 H264/90000
a=rtcp-fb:117 goog-remb
a=rtcp-fb:117 transport-cc
a=rtcp-fb:117 ccm fir
a=rtcp-fb:117 nack
a=rtcp-fb:117 nack pli
a=fmtp:117 \
level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=4d001f
a=rtpmap:118 rtx/90000
a=fmtp:118 apt=117
a=rtpmap:39 H264/90000
a=rtcp-fb:39 goog-remb
a=rtcp-fb:39 transport-cc
a=rtcp-fb:39 ccm fir
a=rtcp-fb:39 nack
a=rtcp-fb:39 nack pli
a=fmtp:39 \
level-asymmetry-allowed=1;packetization-mode=0;profile-level-id=4d001f
a=rtpmap:40 rtx/90000
a=fmtp:40 apt=39
a=rtpmap:41 H264/90000
a=rtcp-fb:41 goog-remb
a=rtcp-fb:41 transport-cc
a=rtcp-fb:41 ccm fir
a=rtcp-fb:41 nack
a=rtcp-fb:41 nack pli
a=fmtp:41 \
level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=f4001f
a=rtpmap:42 rtx/90000
a=fmtp:42 apt=41
a=rtpmap:43 H264/90000
a=rtcp-fb:43 goog-remb
a=rtcp-fb:43 transport-cc
a=rtcp-fb:43 ccm fir
a=rtcp-fb:43 nack
a=rtcp-fb:43 nack pli
a=fmtp:43 \
level-asymmetry-allowed=1;packetization-mode=0;profile-level-id=f4001f
a=rtpmap:44 rtx/90000
a=fmtp:44 apt=43
a=rtpmap:45 AV1/90000
a=rtcp-fb:45 goog-remb
a=rtcp-fb:45 transport-cc
a=rtcp-fb:45 ccm fir
a=rtcp-fb:45 nack
a=rtcp-fb:45 nack pli
a=fmtp:45 level-idx=5;profile=0;tier=0
a=rtpmap:46 rtx/90000
a=fmtp:46 apt=45
a=rtpmap:47 AV1/90000
a=rtcp-fb:47 goog-remb
a=rtcp-fb:47 transport-cc
a=rtcp-fb:47 ccm fir
a=rtcp-fb:47 nack
a=rtcp-fb:47 nack pli
a=fmtp:47 level-idx=5;profile=1;tier=0
a=rtpmap:48 rtx/90000
a=fmtp:48 apt=47
a=rtpmap:119 H264/90000
a=rtcp-fb:119 goog-remb
a=rtcp-fb:119 transport-cc
a=rtcp-fb:119 ccm fir
a=rtcp-fb:119 nack
a=rtcp-fb:119 nack pli
a=fmtp:119 \
level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=64001f
a=rtpmap:120 rtx/90000
a=fmtp:120 apt=119
a=rtpmap:121 H264/90000
a=rtcp-fb:121 goog-remb
a=rtcp-fb:121 transport-cc
a=rtcp-fb:121 ccm fir
a=rtcp-fb:121 nack
a=rtcp-fb:121 nack pli
a=fmtp:121 \
level-asymmetry-allowed=1;packetization-mode=0;profile-level-id=64001f
a=rtpmap:122 rtx/90000
a=fmtp:122 apt=121
a=rtpmap:49 H265/90000
a=rtcp-fb:49 goog-remb
a=rtcp-fb:49 transport-cc
a=rtcp-fb:49 ccm fir
a=rtcp-fb:49 nack
a=rtcp-fb:49 nack pli
a=fmtp:49 level-id=180;profile-id=1;tier-flag=0;tx-mode=SRST
a=rtpmap:50 rtx/90000
a=fmtp:50 apt=49
a=rtpmap:51 H265/90000
a=rtcp-fb:51 goog-remb
a=rtcp-fb:51 transport-cc
a=rtcp-fb:51 ccm fir
a=rtcp-fb:51 nack
a=rtcp-fb:51 nack pli
a=fmtp:51 level-id=180;profile-id=2;tier-flag=0;tx-mode=SRST
a=rtpmap:52 rtx/90000
a=fmtp:52 apt=51
a=rtpmap:123 red/90000
a=rtpmap:124 rtx/90000
a=fmtp:124 apt=123
a=rtpmap:125 ulpfec/90000
a=rtpmap:53 flexfec-03/90000
a=rtcp-fb:53 goog-remb
a=rtcp-fb:53 transport-cc
a=fmtp:53 repair-window=10000000
"""
}
