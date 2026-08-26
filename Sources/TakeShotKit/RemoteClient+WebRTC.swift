import CaptureCore
import Foundation

/// The signalling route, on the connection that carried it: one POST in, one
/// SDP answer out, behind the same PIN as everything else — and beside it the
/// one route that changes what an already-connected browser is watching.
///
/// Split out of `RemoteClient+Reading` the way the frame stream is — this is
/// its own discipline, and the reading half is about HTTP rather than about
/// what any one route means.
///
/// **The PIN goes in the body and not in a query string.** This is a `fetch`,
/// which carries one, so nothing forces the code into a URL the way the
/// poster's `<img>` does — and a URL is the one place a code can end up in a
/// proxy log or a browser history. It goes through the same door either way
/// (`RemoteServer.checkPIN`), and pays the same tarpit, because an endpoint
/// that says yes or no to a code for free is the same four digits with the
/// delay switched off.
///
/// **Why the picture is behind the PIN at all**, when the page markup is not:
/// a live feed of the monitor is the production, frame for frame. The camera
/// grid's JPEGs are gated for exactly this reason and this is the same footage
/// at a better frame rate.
extension RemoteClient {
    /// `POST /webrtc-offer` — `{"pin":"1234","sdp":"v=0…","picture":"clean"}`
    /// in, the answer SDP out with the viewer's id on it.
    func serveWebRTCOffer(_ body: Data) {
        guard let server, let parsed = RemoteWebRTC.parse(body) else {
            // Not a request this route understands, and NOT a PIN guess: it
            // never reached the comparison, so it is not charged for one. A 400
            // says the body was wrong, which is the only thing the page can act
            // on.
            writeAndClose(RemoteResponse.badRequest())
            return
        }
        // The same door the socket's handshake goes through, and never `exempt`:
        // an HTTP request has shown nothing this server can remember.
        switch server.checkPIN(parsed.pin, peer: peer, exempt: false) {
        case .silent:
            // This peer already has a PIN answer on the way: the guess is
            // counted and this request gets no response at all. Closed rather
            // than left hanging — an unanswered POST that kept its connection
            // slot for fifteen seconds would hand the enumeration the socket
            // exhaustion for free. The page reads a dropped connection as a
            // failed offer and makes another.
            close(code: nil)
        case .accepted(let hold):
            holdForTarpit(hold) { [weak self] in
                self?.dispatchWebRTCOffer(parsed.sdp, picture: parsed.picture)
            }
        case .refused(let hold):
            holdForTarpit(hold) { [weak self] in
                self?.writeAndClose(RemoteResponse.forbidden())
            }
        }
    }

    /// `POST /live-picture` — `{"pin":"1234","viewer":"…","picture":"grid"}`
    /// in, nothing but a status out.
    ///
    /// The same door, the same tarpit and the same refusals as the offer route,
    /// deliberately: this carries the PIN too, so an endpoint that answered it
    /// for free would be the same four digits with the delay switched off. The
    /// viewer id is NOT a second secret and is not treated as one — it names a
    /// connection somebody already got past the PIN to make, and the worst a
    /// guessed one can do to a crew is move a colleague's picture, which they
    /// can move straight back.
    func serveLivePictureChange(_ body: Data) {
        guard let server,
              let parsed = RemoteWebRTC.parsePictureChange(body) else {
            writeAndClose(RemoteResponse.badRequest())
            return
        }
        switch server.checkPIN(parsed.pin, peer: peer, exempt: false) {
        case .silent:
            close(code: nil)
        case .accepted(let hold):
            holdForTarpit(hold) { [weak self] in
                self?.dispatchPictureChange(parsed.viewer,
                                            picture: parsed.picture)
            }
        case .refused(let hold):
            holdForTarpit(hold) { [weak self] in
                self?.writeAndClose(RemoteResponse.forbidden())
            }
        }
    }

    /// Hand the change to the app and answer with whether it landed.
    ///
    /// 404 for a viewer the app does not have, which is not an error so much as
    /// news: the connection ended while the tap was in flight. The page answers
    /// it by offering again with the picture it wanted, so the worst case is
    /// the re-offer this route exists to avoid rather than a page stuck on the
    /// wrong picture.
    private func dispatchPictureChange(_ viewer: String,
                                       picture: LivePicture) {
        guard let server, let queue else {
            writeAndClose(RemoteResponse.notFound())
            return
        }
        let id = ObjectIdentifier(self)
        server.handlers.webrtcPicture(viewer, picture) { [weak server] changed in
            guard let server else { return }
            queue.async { [weak server] in
                guard let client = server?.clients[id], !client.closed else {
                    return
                }
                client.writeAndClose(changed ? RemoteResponse.done()
                                        : RemoteResponse.notFound())
            }
        }
    }

    /// Hand the offer to the app and answer with whatever comes back.
    ///
    /// The same hand-off shape the poster route uses, and for the same reason:
    /// nothing that is not Sendable crosses, the app answers from wherever its
    /// work finishes — here a queue that BLOCKS on ICE gathering — and the
    /// connection is looked up again on the server's queue once it does. A
    /// client dropped in the meantime is simply no longer in the registry.
    private func dispatchWebRTCOffer(_ sdp: String, picture: LivePicture) {
        guard let server, let queue else {
            writeAndClose(RemoteResponse.notFound())
            return
        }
        let id = ObjectIdentifier(self)
        server.handlers.webrtcOffer(sdp, picture) { [weak server] answer in
            // Resolved HERE, once — a weak capture is a variable in the closure
            // that holds it, and reading it again inside the hop below would be
            // two threads reading one variable.
            guard let server else { return }
            queue.async { [weak server] in
                guard let client = server?.clients[id], !client.closed else {
                    return
                }
                client.writeAndClose(Self.response(for: answer))
            }
        }
    }

    /// The three answers as the three responses they have to be.
    ///
    /// 503 and not 400 for `unavailable`, and that distinction is the whole
    /// point of the enum: a build with no libdatachannel in it will never
    /// answer, so the page has to stop offering and say why — where a rejected
    /// offer is worth making differently. The reason travels as the body
    /// because it names what to install, and a status code cannot.
    static func response(for answer: RemoteWebRTC.Answer) -> Data {
        switch answer {
        case .answered(let sdp, let viewer):
            return RemoteResponse.sdp(sdp, viewer: viewer)
        case .rejected: return RemoteResponse.badRequest()
        case .unavailable(let reason):
            return RemoteResponse.unavailable(reason)
        }
    }
}
