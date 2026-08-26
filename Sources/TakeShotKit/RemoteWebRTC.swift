import CaptureCore
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

    /// Where the page POSTs a picture it has already got a connection for.
    ///
    /// **A second route rather than a second offer**, and that is the whole
    /// reason it exists: re-offering would mean a fresh DTLS handshake and a
    /// fresh ICE check for a button somebody just pressed, and the picture
    /// would be black until both finished. This changes which session the
    /// existing connection is fed from and nothing else (`WebRTCViewer.watch`).
    ///
    /// Shaped exactly like the offer route — same PIN door, same tarpit, same
    /// body ceiling — because it is the same kind of request from the same page
    /// and a second set of rules would be a second thing to get wrong.
    static let picturePath = "/live-picture"

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
    /// The JSON field naming which picture the page wants to watch — a
    /// `LivePicture` raw value. Both routes carry it, because both are the page
    /// stating the same choice.
    static let pictureField = "picture"
    /// The JSON field carrying the viewer id the answer handed out.
    static let viewerField = "viewer"

    /// The response header the answer's viewer id travels in.
    ///
    /// A header rather than a field in the body, because the body IS the SDP:
    /// wrapping it in JSON to carry one identifier would make the answer route
    /// stop answering `application/sdp`, and the page would have to unwrap
    /// something before handing it to `setRemoteDescription`. Reading a custom
    /// response header is free on a same-origin `fetch`, which every request
    /// this page makes is.
    ///
    /// Deliberately NOT the SSRC out of the answer SDP, which is also an
    /// identifier the page could read: that SDP is written by libdatachannel
    /// and its formatting is the one thing in this feature no test here can
    /// pin (see the note at the top of `WebRTCOffer`).
    static let viewerHeader = "X-TakeShot-Viewer"

    /// What the app answers a POSTed offer with.
    ///
    /// Three cases because they need three different responses and the page
    /// does three different things about them: play the picture, report that
    /// the browser offered something this app cannot carry, or say the feature
    /// is absent from this build and STOP retrying — which is the one a release
    /// made without the library gives everybody, and the one that has to read
    /// as an explanation rather than as a network fault.
    enum Answer: Equatable, Sendable {
        /// The SDP to play, and the id that names this viewer for as long as it
        /// lasts — what the page sends back to change its picture.
        case answered(sdp: String, viewer: String)
        case rejected
        case unavailable(String)
    }

    /// One offer, as the page sends it.
    struct Offer: Equatable, Sendable {
        var pin: String
        var sdp: String
        var picture: LivePicture
    }

    /// One picture change, as the page sends it.
    struct PictureChange: Equatable, Sendable {
        var pin: String
        var viewer: String
        var picture: LivePicture
    }

    /// `{"pin":"1234","sdp":"v=0\r\n…","picture":"clean"}` as its fields.
    ///
    /// nil for anything else, which the route answers 400 to. Strict about the
    /// fields being strings: a body with a number where the PIN should be must
    /// not be read as an empty code and charged to the tarpit as a guess.
    ///
    /// Pure, so the shape of what the page sends is checkable without a socket.
    static func parse(_ body: Data) -> Offer? {
        guard let dictionary = object(in: body),
              let pin = dictionary[pinField] as? String,
              let sdp = dictionary[sdpField] as? String, !sdp.isEmpty,
              let picture = picture(in: dictionary) else { return nil }
        return Offer(pin: pin, sdp: sdp, picture: picture)
    }

    /// `{"pin":"1234","viewer":"…","picture":"grid"}` as its fields.
    static func parsePictureChange(_ body: Data) -> PictureChange? {
        guard let dictionary = object(in: body),
              let pin = dictionary[pinField] as? String,
              let viewer = dictionary[viewerField] as? String, !viewer.isEmpty,
              let picture = picture(in: dictionary) else { return nil }
        return PictureChange(pin: pin, viewer: viewer, picture: picture)
    }

    /// The picture a body names.
    ///
    /// **Absent means `.decorated`, and present-but-unknown means refuse.** The
    /// two are different mistakes: a body with no `picture` in it is a client
    /// that predates the choice — including every `curl` anybody has written
    /// against this route — and the picture this seam has always carried is the
    /// honest answer for it. A body naming a word this app does not have is a
    /// client asking for something specific, and quietly giving it the other
    /// picture is how a stream ends up carrying a burn-in nobody asked for.
    /// Same reasoning as `RemoteCommand.parse`'s unknown rating word.
    private static func picture(in dictionary: [String: Any]) -> LivePicture? {
        guard let named = dictionary[pictureField] else { return .decorated }
        guard let text = named as? String else { return nil }
        return LivePicture(rawValue: text)
    }

    private static func object(in body: Data) -> [String: Any]? {
        guard let parsed = try? JSONSerialization.jsonObject(with: body)
        else { return nil }
        return parsed as? [String: Any]
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
