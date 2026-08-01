import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// The remote driven the way a phone drives it: a real listener, a real HTTP
/// fetch of the page, a real WebSocket. Everything is asserted through
/// controller state, because the point of the feature is that a phone pressing
/// REC goes down the same path as a finger pressing REC.
///
/// Lifecycle — the port, the PIN, the switch — is next door in
/// `RemoteLifecycleTests`. The scaffolding both use is in `RemoteTestSupport`,
/// including why every listener here binds port 0.
@Suite @MainActor struct RemoteServerTests {
    // MARK: - the page

    @Test func thePageIsServedOverHTTP() async throws {
        try await ControllerHarness.run { controller, _ in
            let (port, _) = try await RemoteHarness.serve(controller)
            let url = try #require(URL(string: "http://127.0.0.1:\(port)/"))
            let (data, response) = try await RemoteHarness.session().data(from: url)
            let http = try #require(response as? HTTPURLResponse)

            #expect(http.statusCode == 200)
            #expect(http.value(forHTTPHeaderField: "Content-Type")
                == "text/html; charset=utf-8")
            let html = try #require(String(bytes: data, encoding: .utf8))
            #expect(html.contains("<!doctype html>"))
            #expect(html.contains(L("remote_marker")))
            #expect(!html.contains(RemotePage.configToken))
        }
    }

    /// Anything that is not the page or the socket is a 404 — a probe that gets
    /// a 200 for every path is how a scanner concludes there is a filesystem
    /// behind it.
    @Test func anyOtherPathIsNotFound() async throws {
        try await ControllerHarness.run { controller, _ in
            let (port, _) = try await RemoteHarness.serve(controller)
            let url = try #require(URL(string: "http://127.0.0.1:\(port)/../secrets"))
            let (_, response) = try await RemoteHarness.session().data(from: url)
            #expect((response as? HTTPURLResponse)?.statusCode == 404)
        }
    }

    // MARK: - the socket

    @Test func aClientWithTheRightPINIsSentTheStatus() async throws {
        try await ControllerHarness.run { controller, root in
            try RemoteHarness.seedTake(controller, in: root, named: "A001C07",
                                       clip: 7, rating: .good,
                                       markers: [TakeMarker(seconds: 1),
                                                 TakeMarker(seconds: 2)])

            let (port, pin) = try await RemoteHarness.serve(controller)
            let client = try await RemoteHarness.connect(
                port: port, pin: pin, session: RemoteHarness.session())
            defer { client.close() }

            let auth = try await client.next(type: "auth")
            #expect(auth["ok"] as? Bool == true)

            let status = try await client.next(type: "status")
            #expect(status["take"] as? String == "A001C07")
            #expect(status["rating"] as? String == "good")
            #expect(status["markers"] as? Int == 2)
            #expect(status["recording"] as? Bool == false)
        }
    }

    /// The status stream is behind the PIN, not just the commands: timecode and
    /// take names are production data.
    @Test func theWrongPINGetsNeitherControlNorStatus() async throws {
        try await ControllerHarness.run { controller, root in
            try RemoteHarness.seedTake(controller, in: root, named: "A001C08",
                                       clip: 8)
            let (port, pin) = try await RemoteHarness.serve(controller)
            let wrong = pin == "0000" ? "1111" : "0000"

            let client = try await RemoteHarness.connect(
                port: port, pin: wrong, session: RemoteHarness.session())
            defer { client.close() }

            let auth = try await client.next(type: "auth")
            #expect(auth["ok"] as? Bool == false)

            // And a command on that socket does nothing to the take list.
            try await client.send(action: "good", pin: wrong)
            let refused = try await client.next(type: "auth")
            #expect(refused["ok"] as? Bool == false)
            #expect(try #require(controller.takes.first).rating == .none,
                    "a command with the wrong PIN reached the controller")
        }
    }

    /// The button path: a rating command lands on `toggleLastRating`, the same
    /// method the menu item and the hotkey call.
    @Test func aRatingCommandReachesTheController() async throws {
        try await ControllerHarness.run { controller, root in
            try RemoteHarness.seedTake(controller, in: root, named: "A001C09",
                                       clip: 9)
            let (port, pin) = try await RemoteHarness.serve(controller)
            let client = try await RemoteHarness.connect(
                port: port, pin: pin, session: RemoteHarness.session())
            defer { client.close() }
            _ = try await client.next(type: "auth")

            try await client.send(action: "good", pin: pin)
            let rated = await ControllerWait.until {
                controller.takes.first?.rating == .good
            }
            #expect(rated, "the good-take command never reached the controller")

            // The rating buttons are the same toggles the hotkeys drive.
            try await client.send(action: "bad", pin: pin)
            let flipped = await ControllerWait.until {
                controller.takes.first?.rating == .bad
            }
            #expect(flipped)
        }
    }

    /// The whole point of the feature, end to end: the phone starts the take,
    /// drops a marker inside it and stops it, and what lands on the card is an
    /// ordinary take with an ordinary marker on it.
    @Test func aPhoneRollsATakeAndMarksIt() async throws {
        try await ControllerHarness.run(live: true) { controller, _ in
            await ControllerWait.until { controller.signalFormat != nil }
            let (port, pin) = try await RemoteHarness.serve(controller)
            let client = try await RemoteHarness.connect(
                port: port, pin: pin, session: RemoteHarness.session())
            defer { client.close() }
            _ = try await client.next(type: "auth")

            try await client.send(action: "rec", pin: pin)
            let rolling = await ControllerWait.until { controller.isRecording }
            try #require(rolling, "REC from the remote did not start a take")

            try await client.send(action: "marker", pin: pin)
            let marked = await ControllerWait.until {
                controller.recordingMarkers.count == 1
            }
            #expect(marked, "the marker command never reached the take")

            try await client.send(action: "rec", pin: pin)
            await ControllerWait.until { !controller.isRecording }
            await ControllerWait.untilWritten { controller.takes.count == 1 }
            let take = try #require(controller.takes.first)
            #expect(take.markers.count == 1)
            #expect(controller.persistentAlert?.contains("TAKE LOST") != true)
        }
    }

    /// With no capture running there is nothing to record, and the on-screen
    /// button is disabled for exactly that reason. The remote carries the same
    /// guard rather than handing the press to a pipeline that will sit on it.
    @Test func recIsIgnoredWhileNothingIsCapturing() async throws {
        try await ControllerHarness.run { controller, _ in
            #expect(!controller.isCapturing)
            let (port, pin) = try await RemoteHarness.serve(controller)
            let client = try await RemoteHarness.connect(
                port: port, pin: pin, session: RemoteHarness.session())
            defer { client.close() }
            _ = try await client.next(type: "auth")

            try await client.send(action: "rec", pin: pin)
            // A status comes back either way; the assertion is that the state
            // in it is still idle.
            let status = try await client.next(type: "status")
            #expect(status["capturing"] as? Bool == false)
            #expect(status["recording"] as? Bool == false)
            #expect(!controller.isRecording)
        }
    }

    /// The director's phone and the DIT's tablet at once. A second client used
    /// to be the one that revealed a single-connection server.
    @Test func twoClientsBothGetPushes() async throws {
        try await ControllerHarness.run { controller, root in
            try RemoteHarness.seedTake(controller, in: root, named: "A001C10",
                                       clip: 10)
            let (port, pin) = try await RemoteHarness.serve(controller)
            let shared = RemoteHarness.session()
            let first = try await RemoteHarness.connect(port: port, pin: pin,
                                                        session: shared)
            let second = try await RemoteHarness.connect(port: port, pin: pin,
                                                         session: shared)
            defer { first.close(); second.close() }

            _ = try await first.next(type: "auth")
            _ = try await second.next(type: "auth")
            let one = try await first.next(type: "status")
            let two = try await second.next(type: "status")

            #expect(one["take"] as? String == "A001C10")
            #expect(two["take"] as? String == "A001C10")
        }
    }

    /// The client cap is what stops a script from exhausting the app's sockets,
    /// so a connection that finished must give its slot back. More page fetches
    /// than the cap allows, and then a socket that still has to work: if the
    /// finished HTTP connections were still in the registry, this is where it
    /// shows.
    @Test func finishedConnectionsGiveTheirSlotsBack() async throws {
        try await ControllerHarness.run { controller, root in
            try RemoteHarness.seedTake(controller, in: root, named: "A001C12",
                                       clip: 12)
            let (port, pin) = try await RemoteHarness.serve(controller)
            let url = try HTTPURLProbe.url(port: port)
            for _ in 0...RemoteServer.maximumClients {
                #expect(await HTTPURLProbe.reachable(url))
            }

            let client = try await RemoteHarness.connect(
                port: port, pin: pin, session: RemoteHarness.session())
            defer { client.close() }
            let auth = try await client.next(type: "auth")
            #expect(auth["ok"] as? Bool == true,
                    "the page fetches held on to the connection slots")
        }
    }

    // MARK: - a client that stops behaving

    /// A phone that walks out of Wi-Fi range does not send a FIN: the socket
    /// stays open and stops draining, and every status pushed at it after that
    /// only adds to a queue nobody is reading. The server drops it — and the
    /// tablet next to it must not have missed anything while that happened.
    ///
    /// The stalled client is a raw socket that never reads.
    /// `URLSessionWebSocketTask` cannot play this part: it drains eagerly and
    /// buffers in memory, so its window never closes.
    @Test func aStalledClientIsDroppedAndTheOthersKeepTheirPushes() async throws {
        try await ControllerHarness.run { controller, root in
            try RemoteHarness.seedTake(controller, in: root, named: "A001C13",
                                       clip: 13)
            let (port, pin) = try await RemoteHarness.serve(controller)
            let server = try #require(controller.remoteServer)

            let healthy = try await RemoteHarness.connect(
                port: port, pin: pin, session: RemoteHarness.session())
            defer { healthy.close() }
            _ = try await healthy.next(type: "auth")

            let stalled = try RemoteRawSocket(port: port)
            defer { stalled.close() }
            try stalled.handshake()
            stalled.sendHello(pin: pin)
            let joined = await ControllerWait.until { server.clientCount == 2 }
            try #require(joined, "the raw socket never authenticated")

            // Push until the stalled socket's window shuts and the bytes queued
            // behind it pass the ceiling. Long take names rather than more
            // pushes: the kernel and Network.framework absorb megabytes between
            // them before a send stops completing, and a status is 180 bytes —
            // reaching that with real ones takes tens of thousands of them and
            // most of a minute.
            var padded = controller.remoteStatus()
            padded.takeName = String(repeating: "A", count: 16 * 1024)
            var dropped = false
            for _ in 0..<64 where !dropped {
                for _ in 0..<16 { server.broadcast(padded) }
                dropped = await ControllerWait.until({ server.clientCount == 1 },
                                                     timeout: .milliseconds(200))
            }
            #expect(dropped,
                    "a client that stopped reading was buffered without limit")

            // One went, and it was the stalled one: the client that kept reading
            // is the slot still held. Asserted through the count rather than by
            // reading from it, because everything pushed above is queued in front
            // of anything sent from here.
            #expect(server.clientCount == 1)

            // And the server is still serving — a phone picking up now is handed
            // the current state, not the flood.
            controller.takes[0].rating = .bad
            controller.pushRemoteStatus()
            let fresh = try await RemoteHarness.connect(
                port: port, pin: pin, session: RemoteHarness.session())
            defer { fresh.close() }
            #expect(try await fresh.next(type: "auth")["ok"] as? Bool == true)
            let status = try await fresh.next(type: "status")
            #expect(status["rating"] as? String == "bad",
                    "a stalled client cost the server its status stream")
        }
    }

    /// RFC 6455 §5.4: a continuation frame with no message open is a protocol
    /// error. Treating it as a message of its own — or appending it to whatever
    /// came before — assembles a command out of two unrelated halves, and both
    /// halves come off the network.
    @Test func aStrayContinuationFrameIsRefused() async throws {
        try await ControllerHarness.run { controller, _ in
            let (port, pin) = try await RemoteHarness.serve(controller)
            let socket = try RemoteRawSocket(port: port)
            defer { socket.close() }
            try socket.handshake()

            socket.sendFrame(opcode: 0x0,
                             payload: Data(#"{"action":"rec","pin":"\#(pin)"}"#.utf8))

            #expect(socket.closeCode() == 1002)
            let gone = await ControllerWait.until {
                controller.remoteServer?.clientCount == 0
            }
            #expect(gone, "the refused socket kept its slot")
        }
    }
}

/// What the status payload says about the app's MODE, end to end through a
/// real socket (owner item 28). Its own suite: `RemoteServerTests` above is
/// about the server's plumbing, this is about the one payload the page adapts
/// its controls to — and the two grew past the type-length ceiling together.
@Suite @MainActor struct RemoteStatusPayloadTests {
    /// The payload carries the viewer mode — the page shows and hides its
    /// non-REC controls on it — and the marker count counts whatever a marker
    /// press would land on right now. It used to count the LAST take whenever
    /// nothing was recording, so a marker placed on the clip being reviewed
    /// left the phone saying 0.
    @Test func theStatusCarriesTheModeAndTheLiveMarkerCount() async throws {
        try await ControllerHarness.run { controller, root in
            let take = try RemoteHarness.seedTake(
                controller, in: root, named: "A001C14", clip: 14,
                markers: [TakeMarker(seconds: 1)])
            let (port, pin) = try await RemoteHarness.serve(controller)
            let client = try await RemoteHarness.connect(
                port: port, pin: pin, session: RemoteHarness.session())
            defer { client.close() }
            _ = try await client.next(type: "auth")

            // idle in record mode: the last take's markers, and the mode says so
            let idle = try await client.next(type: "status")
            #expect(idle["mode"] as? String == "record")
            #expect(idle["markers"] as? Int == 1)

            // while recording, the count is the take in progress
            controller.isRecording = true
            controller.recordingMarkers = [TakeMarker(seconds: 1),
                                           TakeMarker(seconds: 2)]
            controller.pushRemoteStatus()
            let recording = try await nextStatus(from: client) {
                $0["mode"] as? String == "record" && $0["markers"] as? Int == 2
            }
            #expect(recording, "the take in progress never reached the payload")

            // reviewing a clip: ITS markers are the count — the payload that
            // used to say 0 however many the operator placed
            controller.isRecording = false
            controller.viewerMode = .playback
            controller.playbackURL = take.url
            controller.takes[0].markers = [TakeMarker(seconds: 1),
                                           TakeMarker(seconds: 2),
                                           TakeMarker(seconds: 3)]
            controller.pushRemoteStatus()
            let playback = try await nextStatus(from: client) {
                $0["mode"] as? String == "playback"
                    && $0["markers"] as? Int == 3
            }
            #expect(playback,
                    "the playback clip's markers never reached the payload")
        }
    }

    /// Read statuses until one matches. The stream keeps flowing (immediate
    /// pushes, then the heartbeat), so this is a poll on the outcome with a
    /// read budget — never a wall-clock wait.
    private func nextStatus(from client: RemoteTestClient, reads: Int = 12,
                            matching predicate: ([String: Any]) -> Bool)
        async throws -> Bool {
        for _ in 0..<reads {
            let status = try await client.next(type: "status")
            if predicate(status) { return true }
        }
        return false
    }
}
