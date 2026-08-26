import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// **Choosing in the browser, over the wire.**
///
/// Two halves, and they fail differently. The OFFER names a picture, so a page
/// that has already chosen gets what it chose on its first frame rather than a
/// second later. The CHANGE moves an existing connection, so a director
/// pressing a button does not pay for a DTLS handshake and a black rectangle.
///
/// The change route is shaped exactly like the offer route — same PIN door,
/// same tarpit, same refusals — and the cases below are the ones that would
/// each be a different kind of hole if it were not.
@MainActor
struct LivePictureRouteTests {
    /// A page that asked for the clean picture is watching the clean picture.
    @Test func theOfferNamesThePictureAndTheAnswerHonoursIt() async throws {
        let peers = WebRTCPeerLog()
        try await ControllerHarness.run { controller, _ in
            controller.mirrors.webrtcPeerFactory = { peers.build($0, $1) }
            let served = try await RemoteHarness.serve(controller)
            let reply = try await WebRTCHarness.offer(
                port: served.port, pin: served.pin, picture: .clean)
            #expect(reply.status == 200)
            let viewer: WebRTCViewer =
                try #require(controller.mirrors.webrtcViewers.values.first)
            #expect(viewer.picture == .clean)
            #expect(Set(controller.mirrors.liveEncoders.keys) == [.clean],
                    "the app built a session for a picture nobody asked for")
        }
    }

    /// An offer with no picture in it is answered with the decorated one.
    ///
    /// The compatible default, and it is a decision rather than an accident:
    /// that is the picture this seam has always carried and the one the SRT
    /// link takes, so a client that predates the choice gets what it used to.
    @Test func anOfferWithNoPictureGetsTheOneThisSeamAlwaysCarried()
        async throws {
        let peers = WebRTCPeerLog()
        try await ControllerHarness.run { controller, _ in
            controller.mirrors.webrtcPeerFactory = { peers.build($0, $1) }
            let served = try await RemoteHarness.serve(controller)
            let object: [String: Any] = [
                RemoteWebRTC.pinField: served.pin,
                RemoteWebRTC.sdpField: WebRTCOfferFixture.chromeRecvOnlyVideo,
            ]
            let reply = try await WebRTCHarness.post(
                port: served.port,
                body: try JSONSerialization.data(withJSONObject: object))
            #expect(reply.status == 200)
            #expect(Set(controller.mirrors.liveEncoders.keys) == [.decorated])
        }
    }

    /// A picture this app does not have is REFUSED rather than quietly given
    /// the default.
    ///
    /// The opposite treatment to an absent field, and the difference is what a
    /// client meant: silence has an honest answer, and a specific request for
    /// something that does not exist does not. Answering it with the decorated
    /// frame is how a stream ends up carrying a burn-in nobody asked for.
    @Test func aPictureThisAppDoesNotHaveIsRefused() async throws {
        let peers = WebRTCPeerLog()
        try await ControllerHarness.run { controller, _ in
            controller.mirrors.webrtcPeerFactory = { peers.build($0, $1) }
            let served = try await RemoteHarness.serve(controller)
            let object: [String: Any] = [
                RemoteWebRTC.pinField: served.pin,
                RemoteWebRTC.sdpField: WebRTCOfferFixture.chromeRecvOnlyVideo,
                RemoteWebRTC.pictureField: "waveform",
            ]
            let reply = try await WebRTCHarness.post(
                port: served.port,
                body: try JSONSerialization.data(withJSONObject: object))
            #expect(reply.status == 400)
            #expect(peers.all.isEmpty, "a refused offer still built a peer")
            #expect(controller.mirrors.liveEncoders.isEmpty)
        }
    }

    /// The answer names the viewer, in a header, with the SDP still the body.
    ///
    /// Both halves matter: without the id the page has nothing to send back and
    /// the only way to change picture is a re-offer; with the id in the body
    /// the page would have to unwrap something before
    /// `setRemoteDescription`.
    @Test func theAnswerNamesTheViewerWithoutDisturbingTheSDP() async throws {
        let peers = WebRTCPeerLog()
        try await ControllerHarness.run { controller, _ in
            controller.mirrors.webrtcPeerFactory = { peers.build($0, $1) }
            let served = try await RemoteHarness.serve(controller)
            let reply = try await WebRTCHarness.offer(port: served.port,
                                                      pin: served.pin)
            #expect(reply.contentType == "application/sdp")
            #expect(reply.body.hasPrefix("v=0"))
            let named: UUID = try #require(UUID(uuidString: reply.viewer),
                                           "no viewer id on the answer")
            #expect(controller.mirrors.webrtcViewers[named] != nil,
                    "the id names no viewer this app is holding")
        }
    }

    /// **The change that does not tear the connection down.**
    ///
    /// The peer is the same object, it was never closed, and the picture moved
    /// — which together are the whole claim. The session it left is released
    /// with it, because it was the only thing on it.
    @Test func aPictureChangeMovesTheStreamWithoutANewConnection() async throws {
        let peers = WebRTCPeerLog()
        try await ControllerHarness.run { controller, _ in
            controller.mirrors.webrtcPeerFactory = { peers.build($0, $1) }
            let served = try await RemoteHarness.serve(controller)
            let answer = try await WebRTCHarness.offer(port: served.port,
                                                       pin: served.pin,
                                                       picture: .decorated)
            let peer: FakeWebRTCPeer = try #require(peers.latest)
            peer.report(.connected)

            let reply = try await WebRTCHarness.changePicture(
                port: served.port, pin: served.pin, viewer: answer.viewer,
                to: LivePicture.grid.rawValue)
            #expect(reply.status == 200)

            #expect(peers.all.count == 1,
                    "the change built a second peer connection")
            #expect(!peer.isClosed, "the change closed the connection")
            let viewer: WebRTCViewer =
                try #require(controller.mirrors.webrtcViewers.values.first)
            #expect(await ControllerWait.until { viewer.picture == .grid })
            // And the arithmetic follows the move: the picture it went to is
            // being encoded, the one it left is not.
            #expect(await ControllerWait.until {
                Set(controller.mirrors.liveEncoders.keys) == [.grid]
            }, "sessions after the change: \(controller.mirrors.liveEncoders.keys)")
        }
    }

    /// A change for a viewer this app does not have is 404 — news, not an
    /// error. The page answers it by offering again with the picture it wanted.
    @Test func aChangeForAViewerThatIsGoneIsNotFound() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.mirrors.webrtcPeerFactory = { WebRTCPeerLog().build($0, $1) }
            let served = try await RemoteHarness.serve(controller)
            let reply = try await WebRTCHarness.changePicture(
                port: served.port, pin: served.pin,
                viewer: UUID().uuidString, to: LivePicture.clean.rawValue)
            #expect(reply.status == 404)
            #expect(controller.mirrors.liveEncoders.isEmpty,
                    "a change nobody could act on still built a session")
        }
    }

    /// The change route is behind the same PIN as everything else, and it is a
    /// picture of the production like the rest of it.
    @Test func theWrongPINCannotMoveSomebodyElsesPicture() async throws {
        let peers = WebRTCPeerLog()
        try await ControllerHarness.run { controller, _ in
            controller.mirrors.webrtcPeerFactory = { peers.build($0, $1) }
            let served = try await RemoteHarness.serve(controller)
            let answer = try await WebRTCHarness.offer(port: served.port,
                                                       pin: served.pin,
                                                       picture: .decorated)
            let server: RemoteServer = try #require(controller.remoteServer)
            #expect(await RemoteHarness.pinSlotFree(server))

            let reply = try await WebRTCHarness.changePicture(
                port: served.port,
                pin: RemoteHarness.wrongPIN(besides: served.pin),
                viewer: answer.viewer, to: LivePicture.clean.rawValue)
            #expect(reply.status == 403)
            let viewer: WebRTCViewer =
                try #require(controller.mirrors.webrtcViewers.values.first)
            #expect(viewer.picture == .decorated,
                    "a wrong code moved a viewer's picture")
        }
    }

    /// A change naming a picture this app does not have is 400, and the viewer
    /// is left exactly where it was.
    @Test func aChangeToAPictureThisAppDoesNotHaveIsRefused() async throws {
        let peers = WebRTCPeerLog()
        try await ControllerHarness.run { controller, _ in
            controller.mirrors.webrtcPeerFactory = { peers.build($0, $1) }
            let served = try await RemoteHarness.serve(controller)
            let answer = try await WebRTCHarness.offer(port: served.port,
                                                       pin: served.pin,
                                                       picture: .clean)
            let reply = try await WebRTCHarness.changePicture(
                port: served.port, pin: served.pin, viewer: answer.viewer,
                to: "vectorscope")
            #expect(reply.status == 400)
            let viewer: WebRTCViewer =
                try #require(controller.mirrors.webrtcViewers.values.first)
            #expect(viewer.picture == .clean)
            #expect(Set(controller.mirrors.liveEncoders.keys) == [.clean])
        }
    }

    /// The body's shape on its own, without a socket in the way.
    ///
    /// Every case here is a boundary that a route test can only reach one of at
    /// a time, and the two strict ones are the interesting pair: a body with no
    /// picture is a client that predates the choice, and a body with a picture
    /// this app does not have is a client asking for something specific.
    @Test func thePictureFieldIsReadStrictly() throws {
        let plain: RemoteWebRTC.Offer = try #require(RemoteWebRTC.parse(
            Data(#"{"pin":"1234","sdp":"v=0"}"#.utf8)))
        #expect(plain.picture == .decorated)
        let named: RemoteWebRTC.Offer = try #require(RemoteWebRTC.parse(
            Data(#"{"pin":"1","sdp":"v=0","picture":"grid"}"#.utf8)))
        #expect(named.picture == .grid)
        #expect(RemoteWebRTC.parse(
            Data(#"{"pin":"1","sdp":"v=0","picture":"nope"}"#.utf8)) == nil)
        // A number is not a picture name, and must not be read as an absent
        // field — the same strictness the PIN field gets one line up.
        #expect(RemoteWebRTC.parse(
            Data(#"{"pin":"1","sdp":"v=0","picture":3}"#.utf8)) == nil)

        let change: RemoteWebRTC.PictureChange =
            try #require(RemoteWebRTC.parsePictureChange(
                Data(#"{"pin":"1","viewer":"abc","picture":"clean"}"#.utf8)))
        #expect(change == RemoteWebRTC.PictureChange(pin: "1", viewer: "abc",
                                                     picture: .clean))
        #expect(RemoteWebRTC.parsePictureChange(
            Data(#"{"pin":"1","picture":"clean"}"#.utf8)) == nil)
        #expect(RemoteWebRTC.parsePictureChange(
            Data(#"{"pin":"1","viewer":"","picture":"clean"}"#.utf8)) == nil)
        #expect(RemoteWebRTC.parsePictureChange(Data("[]".utf8)) == nil)
    }
}
