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
            #expect(!controller.showsATakeLostAlarm)
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

            // The healthy client has to actually read for the whole flood:
            // URLSessionWebSocketTask only drains the wire while a receive is
            // pending, and a "healthy" client nobody reads from fills its own
            // window a few pushes after the stalled one — on a loaded run both
            // then cross the in-flight ceiling between two polls, the count
            // skips from 2 to 0, and this test was the suite's flake. The
            // drain also remembers whether the post-drop status got through,
            // which is the "keeps their pushes" being claimed — and says so
            // itself if its own socket is the one that goes (see RemoteDrain).
            let drain = RemoteDrain(healthy)
            defer { drain.stop() }

            let stalled = try RemoteRawSocket(port: port)
            defer { stalled.close() }
            try stalled.handshake()
            stalled.sendHello(pin: pin)
            let joined = await ControllerWait.until { server.clientCount == 2 }
            try #require(joined, "the raw socket never authenticated")

            let dropped = await Self.floodUntilOneDrops(
                server, status: controller.remoteStatus(), received: drain.texts)
            #expect(dropped,
                    "a client that stopped reading was buffered without limit")

            // One went, and it was the stalled one. WHICH slot is still held
            // is not visible in the count — the drain above is what says it,
            // by recording an issue the moment the reading client's socket
            // fails. A bare `== 1` was true in the run that went red on CI.
            #expect(server.clientCount == 1,
                    "exactly one client went; the drain says which")

            // And its pushes still flow: the status sent AFTER the drop
            // reaches it. First the send ledger has to drain — the reader has
            // the flood's bytes, but a completion still in flight counts
            // against the drop ceiling, and a push behind an unsettled message
            // drops the very client being asserted alive (that race, at
            // sixteen unpolled sends a round, was this suite's first flake;
            // `floodPadding` is what closed the rest of it).
            //
            // Both waits take the I/O budget, and the drain is REQUIRED rather
            // than discarded. This is what the second flake was: on the CI
            // runner under coverage instrumentation the ledger needs longer
            // than the interactive ten seconds to settle, and an ignored
            // `until` let the test push into an unsettled server and then
            // report "the reading client lost its status stream" — blaming the
            // server for a wait that had simply run out. A wait whose outcome
            // IS the precondition has to fail on itself; see
            // TestWait.becomesTrue for the same rule stated.
            let settled = await ControllerWait.untilWritten {
                server.maxClientInFlight == 0
            }
            try #require(
                settled,
                "the send ledger never drained; this measures the flood")
            controller.takes[0].rating = .bad
            controller.pushRemoteStatus()
            let heard = await ControllerWait.untilWritten {
                drain.badRatings.value > 0
            }
            #expect(heard, "the reading client lost its status stream")

            try await Self.aFreshPhoneIsHandedTheCurrentState(port: port,
                                                              pin: pin)
        }
    }

    /// A phone picking up after all that is handed the state as it stands, not
    /// the flood's backlog.
    ///
    /// Its own function because the test above reached the body-length ceiling
    /// when its two waits were given honest budgets — and this is a separate
    /// claim about the server anyway: the first two phases are about who gets
    /// dropped and who keeps their stream, this one is about what a newcomer
    /// sees.
    private static func aFreshPhoneIsHandedTheCurrentState(
        port: Int, pin: String) async throws {
        let fresh = try await RemoteHarness.connect(
            port: port, pin: pin, session: RemoteHarness.session())
        defer { fresh.close() }
        #expect(try await fresh.next(type: "auth")["ok"] as? Bool == true)
        let status = try await fresh.next(type: "status")
        #expect(status["rating"] as? String == "bad",
                "a stalled client cost the server its status stream")
    }

    /// How much the flood pads a status by, and the whole reason this test
    /// stopped being the suite's flake.
    ///
    /// Padding at all is necessary: loopback socket buffers autotune into the
    /// megabytes, so a send on the stalled socket keeps completing until
    /// several MB have gone nowhere, and at a bare status of 180 bytes that
    /// is most of a minute of round trips.
    ///
    /// Padding to more than the ceiling is what was wrong. A message larger
    /// than `RemoteClient.maximumInFlight` puts EVERY client's ledger over the
    /// limit for as long as its bytes are on the wire — the reading one
    /// included — and the app's own status tick fires four times a second
    /// (`CaptureController.remoteTick`) into that window. `write` then closes
    /// the very client this test asserts alive, with 1011, and the test's
    /// reader dies with it. The old padding was 512 KB, sixteen times the
    /// ceiling; here that window is microseconds and on the runner it is long
    /// enough to catch a tick, which is exactly the CI-only failure. It
    /// reproduces on this machine in one run by broadcasting one extra status
    /// inside the window.
    ///
    /// A quarter of the ceiling is the size, and the fraction is the point
    /// rather than the number: a client that is DRAINING is then at most a
    /// quarter of the way to the limit when a tick arrives, so no interleaving
    /// of the tick and one flood message can reach it, and only a socket that
    /// stopped draining accumulates — which is the property under test. It is
    /// still forty-five times a bare status, so the wire fills in round trips
    /// rather than in minutes.
    private static let floodPadding: Int = RemoteClient.maximumInFlight / 4

    /// Push until the stalled socket's window shuts and the bytes queued
    /// behind it pass the ceiling.
    ///
    /// One push per RECEIPT: waiting for the reading client to take each
    /// message before the next goes out means its completion is already queued
    /// ahead of the next broadcast on the server's own serial queue, so its
    /// in-flight bytes never see two flood messages. (The old shape — bursts
    /// of sixteen, unpolled — relied on outracing the send completions, and
    /// under load it dropped the reading client too.)
    ///
    /// The exit is an OUTCOME — a client actually going — and the round cap is
    /// only a runaway backstop. The wedge arrives after however many bytes
    /// this machine's loopback absorbs: measured here at 137 rounds, i.e. 1.1
    /// MB, three runs in a row to the round. A thousand leaves room for a pipe
    /// eight times as deep, which is the direction a slower machine could
    /// differ in; a cap a slow machine cannot reach would turn a wedge that
    /// merely took longer into a failure about the server.
    ///
    /// A receipt that never comes ends the flood rather than burning the rest
    /// of the cap ten seconds at a time: the reading client has stopped taking
    /// messages, so there is nothing left to push against, and the drain has
    /// already recorded why.
    @MainActor
    private static func floodUntilOneDrops(_ server: RemoteServer,
                                           status: RemoteStatus,
                                           received: HitCounter) async -> Bool {
        var padded = status
        padded.takeName = String(repeating: "A", count: floodPadding)
        var dropped = false
        var rounds = 0
        while !dropped, rounds < 1024 {
            rounds += 1
            server.broadcast(padded)
            let sent = rounds
            let receipted: Bool = await ControllerWait.until {
                received.value >= sent || server.clientCount < 2
            }
            dropped = server.clientCount < 2
            if !receipted { break }
        }
        return dropped
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
