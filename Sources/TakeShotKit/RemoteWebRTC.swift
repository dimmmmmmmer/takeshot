import Foundation

/// Signalling, which on this network is one POST.
///
/// **There is no signalling server, no STUN and no TURN, and that is a decision
/// rather than a simplification.** The phone and the Mac are on one set network
/// by construction — outside it is out of scope — so host candidates are the
/// whole of ICE, and the only thing the two ends have to exchange is one offer
/// and one answer. A WebSocket channel, a candidate stream and an ordering
/// problem all disappear if both ends finish gathering BEFORE they speak: the
/// page POSTs its offer with every candidate already in it, and the answer comes
/// back with every candidate already in that. One request, one response, nothing
/// to keep open, nothing to reconnect.
///
/// It rides the server the phones already talk to, behind the PIN they already
/// have. A second listener would be a second port to read out, a second thing to
/// bind and a second door onto the recorder.
enum RemoteWebRTC {
    /// Where the page POSTs. Stated once, here, so the route the server answers
    /// and the URL the page builds cannot drift apart — a mismatch shows up as
    /// a page that is permanently "connecting".
    static let offerPath = "/webrtc-offer"

    /// Longest request body the route will take.
    ///
    /// An offer is SDP, and a browser's video offer is two to four kilobytes:
    /// the codec list is most of it and the candidates are a line each. Sixteen
    /// is several times the largest real one and a fraction of the connection's
    /// own buffer ceiling (`RemoteClient.maximumBuffer`), which is what stops a
    /// request head that never ends. This is the same defence one layer in: a
    /// `Content-Length` a peer states and never sends would otherwise hold a
    /// connection slot to its handshake deadline.
    static let maximumBody = 16 * 1024

    /// The JSON field carrying the four-digit code.
    static let pinField = "pin"
    /// The JSON field carrying the offer SDP.
    static let sdpField = "sdp"

    /// What the app answers a POSTed offer with.
    ///
    /// Three cases because they need three different responses and the page
    /// does three different things about them: play the picture, report that
    /// the browser offered something this app cannot carry, or say the feature
    /// is absent from this build and STOP retrying — which is the one a release
    /// made without the library gives everybody, and the one that has to read
    /// as an explanation rather than as a network fault.
    enum Answer: Equatable, Sendable {
        case answered(String)
        case rejected
        case unavailable(String)
    }

    /// `{"pin":"1234","sdp":"v=0\r\n…"}` as its two fields.
    ///
    /// nil for anything else, which the route answers 400 to. Strict about both
    /// fields being strings: a body with a number where the PIN should be must
    /// not be read as an empty code and charged to the tarpit as a guess.
    ///
    /// Pure, so the shape of what the page sends is checkable without a socket.
    static func parse(_ body: Data) -> (pin: String, sdp: String)? {
        guard let object = try? JSONSerialization.jsonObject(with: body),
              let dictionary = object as? [String: Any],
              let pin = dictionary[pinField] as? String,
              let sdp = dictionary[sdpField] as? String,
              !sdp.isEmpty else { return nil }
        return (pin, sdp)
    }
}

/// What to do with a POST whose head has arrived: read a body of this size, or
/// refuse it.
///
/// **A rule rather than a condition inside the reader**, and for the reason
/// `PunchEventView.decide` is one: the reader can only be reached through a
/// socket, so a test there can afford one case or two — and every interesting
/// case here is a boundary. A `Content-Length` a peer states and never sends
/// holds a connection slot to its handshake deadline, a missing one leaves the
/// reader waiting for bytes nobody promised, and a header of "16384" and one of
/// "16385" have to land on opposite sides of a line drawn in one place.
extension RemoteWebRTC {
    enum BodyVerdict: Equatable, Sendable {
        /// Wait for exactly this many bytes, then route the request.
        case read(Int)
        /// Answer 400 now. The body is absent, unreadable as a number, empty,
        /// or larger than this route will ever carry.
        case refuse
    }

    /// The verdict for a `Content-Length` header value; nil means the header
    /// was absent, which is refused like any other body this route cannot
    /// bound.
    ///
    /// Deliberately strict about the SHAPE of the number as well as its size:
    /// `Int("16 384")` and `Int("+400")` are the sort of thing a hand-written
    /// client sends, and a reader that took either would be waiting on a length
    /// nobody agrees about.
    static func bodyVerdict(contentLength: String?) -> BodyVerdict {
        guard let text = contentLength?.trimmingCharacters(in: .whitespaces),
              !text.isEmpty, text.allSatisfy(\.isASCII),
              text.allSatisfy(\.isNumber), let announced = Int(text),
              announced > 0, announced <= maximumBody else { return .refuse }
        return .read(announced)
    }
}
