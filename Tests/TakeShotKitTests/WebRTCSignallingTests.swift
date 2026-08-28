import CDataChannel
import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// The signalling route: one POST in, one answer out, behind the same PIN as
/// everything else on this server.
///
/// Everything here runs against a real listener on an ephemeral port with a
/// real HTTP client, and a peer connection that never touches a network. What
/// that leaves uncovered is named in the report and in `WebRTCViewer`: no test
/// anywhere proves a browser decodes what comes out.
@Suite @MainActor struct WebRTCSignallingTests {
    /// A well-formed offer with the right code comes back as SDP.
    ///
    /// And the ANSWER is the one built for this offer's own plan — the mid and
    /// the payload type the browser named — rather than a constant: it is the
    /// fake's echo of what the app decided, which is the only part of the
    /// answer this app decides.
    @Test func anOfferBehindTheRightPINComesBackAsAnAnswer() async throws {
        let log = WebRTCPeerLog()
        try await ControllerHarness.run { controller, _ in
            controller.mirrors.webrtcPeerFactory = { log.build($0, $1) }
            let served = try await RemoteHarness.serve(controller)
            let reply = try await WebRTCHarness.offer(port: served.port,
                                                      pin: served.pin)
            #expect(reply.status == 200)
            #expect(reply.contentType.hasPrefix("application/sdp"))
            #expect(reply.body.contains("a=mid:0"))
            #expect(reply.body.contains("UDP/TLS/RTP/SAVPF 119"))
            let peer: FakeWebRTCPeer = try #require(log.latest)
            #expect(peer.offers.count == 1)
            #expect(peer.offers[0].contains("a=ice-ufrag:STJI"),
                    "the browser's own offer did not reach the peer")
            // And a viewer is being held for it, with the session for the
            // picture it asked for built.
            #expect(controller.mirrors.webrtcViewers.count == 1)
            #expect(controller.mirrors.liveEncoders[.decorated] != nil)
        }
    }

    /// The wrong code is refused, and the offer never reaches the app.
    ///
    /// 403 rather than 400 for the same reason the poster route answers 403: a
    /// stale code has to send the page back to the gate, where a rejected offer
    /// only has it offer again.
    @Test func theWrongPINIsRefusedAndNoPeerIsBuilt() async throws {
        let log = WebRTCPeerLog()
        try await ControllerHarness.run { controller, _ in
            controller.mirrors.webrtcPeerFactory = { log.build($0, $1) }
            let served = try await RemoteHarness.serve(controller)
            let reply = try await WebRTCHarness.offer(
                port: served.port,
                pin: RemoteHarness.wrongPIN(besides: served.pin))
            #expect(reply.status == 403)
            #expect(log.all.isEmpty, "a wrong code still built a peer")
            #expect(controller.mirrors.webrtcViewers.isEmpty)
            #expect(controller.mirrors.liveEncoders.isEmpty,
                    "a refused offer built an encoder")
        }
    }

    /// A guess at this route is charged to the tarpit, exactly as a guess at the
    /// socket or the poster is.
    ///
    /// The rule this checks is the one `RemotePINDoorTests` states from the
    /// other side — that a code is compared in one place that always charges —
    /// and it checks it as a MEASUREMENT here: a new endpoint that answered for
    /// free would be the cheapest way to enumerate four digits, and the door
    /// test alone cannot see that this route calls the door at all.
    @Test func aGuessAtThisRouteRaisesThePressureLikeAnyOther() async throws {
        try await ControllerHarness.run { controller, _ in
            let served = try await RemoteHarness.serve(controller)
            let server: RemoteServer = try #require(controller.remoteServer)
            #expect(server.pinPressure == 0)
            _ = try await WebRTCHarness.offer(
                port: served.port,
                pin: RemoteHarness.wrongPIN(besides: served.pin))
            #expect(server.pinPressure > 0,
                    "an offer with a wrong code cost the guesser nothing")
        }
    }

    /// A body that is not the shape this route takes is refused, and the server
    /// is still there afterwards.
    ///
    /// The second half is the point. A route that reads a length off a stranger
    /// and then indexes with it is the classic way to take a recorder down, so
    /// what is asserted is not only the 400 but that a good offer on a fresh
    /// connection is answered right after each bad one.
    @Test func aMalformedBodyIsRefusedWithoutTakingTheServerDown() async throws {
        let log = WebRTCPeerLog()
        try await ControllerHarness.run { controller, _ in
            controller.mirrors.webrtcPeerFactory = { log.build($0, $1) }
            let served = try await RemoteHarness.serve(controller)
            let bodies: [Data] = [
                Data("not json at all".utf8),
                Data("{}".utf8),
                Data(#"{"pin":1234,"sdp":"v=0"}"#.utf8),
                Data(#"{"pin":"1234"}"#.utf8),
                Data([0xFF, 0xFE, 0x00, 0x01]),
            ]
            for body in bodies {
                let reply = try await WebRTCHarness.post(port: served.port,
                                                         body: body)
                #expect(reply.status == 400, "\(reply.status) for \(body.count)B")
            }
            #expect(log.all.isEmpty)
            let good = try await WebRTCHarness.offer(port: served.port,
                                                     pin: served.pin)
            #expect(good.status == 200, "the server stopped answering")
        }
    }

    /// Valid JSON carrying something that is not an answerable offer is a 400
    /// and not a 503: the page can offer differently, and telling it the
    /// feature is missing would be a lie it would act on by giving up.
    @Test func anSDPWithNothingAnswerableInItIsRejected() async throws {
        try await ControllerHarness.run { controller, _ in
            let served = try await RemoteHarness.serve(controller)
            for sdp in ["hello", "v=0\r\nm=audio 9 RTP/AVP 0\r\n",
                        WebRTCOfferFixture.chromeSingleNALOnly] {
                let reply = try await WebRTCHarness.offer(port: served.port,
                                                          pin: served.pin,
                                                          sdp: sdp)
                #expect(reply.status == 400, "\(reply.status) for \(sdp.prefix(9))")
            }
            #expect(controller.mirrors.webrtcViewers.isEmpty)
        }
    }

    /// A body past the ceiling is refused before it is kept.
    ///
    /// An offer is two to four kilobytes; sixteen is several times the largest
    /// real one. Without the ceiling the only bound is the connection's own
    /// 128 KB buffer, and a `Content-Length` a peer states and never finishes
    /// sending holds a connection slot to its handshake deadline.
    @Test func aBodyPastTheCeilingIsRefused() async throws {
        try await ControllerHarness.run { controller, _ in
            let served = try await RemoteHarness.serve(controller)
            let padded = WebRTCOfferFixture.chromeRecvOnlyVideo
                + String(repeating: "a=x-pad:0\r\n", count: 2_000)
            #expect(padded.utf8.count > RemoteWebRTC.maximumBody)
            let reply = try await WebRTCHarness.offer(port: served.port,
                                                      pin: served.pin,
                                                      sdp: padded)
            #expect(reply.status == 400)
        }
    }

    /// The route is a POST. A GET at the same path is a 404 like any other
    /// unknown one — an offer cannot arrive in a URL, and a GET that answered
    /// would be a second door onto the same work.
    @Test func theRouteIsNotReachableWithAGET() async throws {
        try await ControllerHarness.run { controller, _ in
            let served = try await RemoteHarness.serve(controller)
            let url: URL = try #require(URL(
                string: "http://127.0.0.1:\(served.port)"
                    + "\(RemoteWebRTC.offerPath)?pin=\(served.pin)"))
            let (_, response) = try await RemoteHarness.session().data(from: url)
            let http: HTTPURLResponse = try #require(response as? HTTPURLResponse)
            #expect(http.statusCode == 404)
        }
    }

    /// A library that refuses the offer is the app's fault, not the browser's,
    /// and the slot goes back at once.
    @Test func aPeerThatCannotAnswerGivesItsSlotBack() async throws {
        let log = WebRTCPeerLog(failure: .runtime("no interfaces to gather on"))
        try await ControllerHarness.run { controller, _ in
            controller.mirrors.webrtcPeerFactory = { log.build($0, $1) }
            let served = try await RemoteHarness.serve(controller)
            let reply = try await WebRTCHarness.offer(port: served.port,
                                                      pin: served.pin)
            #expect(reply.status == 503)
            #expect(reply.body.contains("no interfaces to gather on"))
            #expect(await ControllerWait.until {
                controller.mirrors.webrtcViewers.isEmpty
            }, "a viewer that never answered kept its slot")
            #expect(await ControllerWait.until {
                controller.mirrors.liveEncoders.isEmpty
            }, "the encoder outlived the last viewer")
        }
    }

    /// Past the ceiling the app says so rather than opening a fifth connection.
    @Test func theViewerSlotsAreBounded() async throws {
        let log = WebRTCPeerLog()
        try await ControllerHarness.run { controller, _ in
            controller.mirrors.webrtcPeerFactory = { log.build($0, $1) }
            let served = try await RemoteHarness.serve(controller)
            for _ in 0..<WebRTCViewer.maximumViewers {
                let reply = try await WebRTCHarness.offer(port: served.port,
                                                          pin: served.pin)
                #expect(reply.status == 200)
            }
            let extra = try await WebRTCHarness.offer(port: served.port,
                                                      pin: served.pin)
            #expect(extra.status == 503)
            #expect(log.all.count == WebRTCViewer.maximumViewers)
        }
    }
}

/// What a build with no libdatachannel does, which is what CI is and what every
/// downloaded release without the library bundled would be.
///
/// **The whole feature has to be absent rather than broken.** The app builds,
/// launches and does everything else it did; the route answers, and what it
/// answers reads as an instruction rather than as a network fault. Gated on the
/// bridge REALLY being unavailable, because on a machine that has the headers
/// and the dylib the honest answer is the other one — and a suite that forced
/// it would have to reach the real peer, which puts UDP on the set network.
@Suite(.enabled(if: !CDCPeerConnection.isSDKAvailable(),
                "this machine has libdatachannel, so the feature is present"))
@MainActor
struct WebRTCUnavailableTests {
    /// With no library, an offer is answered 503 and the body says what is
    /// missing. Not 400: offering differently cannot help, and a page told 400
    /// would keep trying.
    @Test func theRouteReportsItselfUnavailableRatherThanFailing() async throws {
        try await ControllerHarness.run { controller, _ in
            // The harness installs a fake peer for every controller it builds;
            // this suite is about what happens with the REAL one, so it is put
            // back.
            controller.mirrors.webrtcPeerFactory = nil
            let served = try await RemoteHarness.serve(controller)
            let reply = try await WebRTCHarness.offer(port: served.port,
                                                      pin: served.pin)
            #expect(reply.status == 503)
            #expect(reply.body.lowercased().contains("libdatachannel"),
                    "the reason did not name what is missing: \(reply.body)")

            // **And it comes back in the language the page is being served
            // in.** This is the one end-to-end of the /live half: a real
            // socket, the real (stub) bridge, and the body chosen at the
            // moment the route answers rather than baked into the markup.
            // Only reachable in a build with no libdatachannel, which is CI's
            // and every published download's.
            #expect(await RemoteHarness.pinSlotFree(
                try #require(controller.remoteServer)))
            L10n.apply(.russian)
            let translated = try await WebRTCHarness.offer(port: served.port,
                                                           pin: served.pin)
            L10n.apply(.english)
            #expect(translated.status == 503)
            #expect(translated.body != reply.body,
                    "the page reads English with the app set to Russian: \(translated.body)")
            // The library's name is not translated: it is the thing to look up.
            #expect(translated.body.lowercased().contains("libdatachannel"),
                    "\(translated.body)")
            #expect(controller.mirrors.webrtcViewers.isEmpty)
            #expect(controller.mirrors.liveEncoders.isEmpty,
                    "an unavailable feature built an encoder")
        }
    }

    /// **Every picture degrades the same way, and the picture change route
    /// too.**
    ///
    /// The failure this catches is a choice that half-works: an offer refused
    /// with the honest 503 for one picture and a silent 400 (or worse, a
    /// session built for nobody) for another. There is nothing to choose
    /// between on a build with no library, and each of the three has to say so
    /// identically.
    @Test func everyPictureIsAbsentTheSameWay() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.mirrors.webrtcPeerFactory = nil
            let served = try await RemoteHarness.serve(controller)
            for picture in LivePicture.allCases {
                #expect(await RemoteHarness.pinSlotFree(
                    try #require(controller.remoteServer)))
                let reply = try await WebRTCHarness.offer(
                    port: served.port, pin: served.pin, picture: picture)
                #expect(reply.status == 503, "\(picture) answered \(reply.status)")
                #expect(reply.body.lowercased().contains("libdatachannel"),
                        "\(picture): \(reply.body)")
                #expect(reply.viewer.isEmpty,
                        "\(picture) was given a viewer id it cannot use")
            }
            #expect(controller.mirrors.liveEncoders.isEmpty)
            #expect(controller.mirrors.gridComposer == nil,
                    "the grid picture built a composer with nothing to send it to")

            // And the change route has nothing to move, which is a 404 rather
            // than a 503: the app CAN answer it, and the honest answer is that
            // there is no such viewer.
            #expect(await RemoteHarness.pinSlotFree(
                try #require(controller.remoteServer)))
            let change = try await WebRTCHarness.changePicture(
                port: served.port, pin: served.pin, viewer: UUID().uuidString,
                to: LivePicture.clean.rawValue)
            #expect(change.status == 404)
        }
    }

    /// And nothing else changes. The bridge says it is a stub, says why in a
    /// sentence somebody can act on, and every other route on the server
    /// answers exactly as it did.
    @Test func nothingElseAboutTheAppIsDifferent() async throws {
        #expect(CDCPeerConnection.isSDKAvailable() == false)
        let reason: String = try #require(CDCPeerConnection.unavailableReason())
        #expect(reason.contains("vendor/libdatachannel/README.md"),
                "the reason is not an instruction: \(reason)")
        try await ControllerHarness.run { controller, _ in
            controller.mirrors.webrtcPeerFactory = nil
            let served = try await RemoteHarness.serve(controller)
            let url: URL = try #require(
                URL(string: "http://127.0.0.1:\(served.port)/"))
            let (body, response) = try await RemoteHarness.session().data(from: url)
            let http: HTTPURLResponse = try #require(response as? HTTPURLResponse)
            #expect(http.statusCode == 200)
            #expect(!body.isEmpty)
        }
    }
}
