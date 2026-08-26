import AppKit
import CaptureCore
import CoreImage
import CoreVideo
import Foundation
import JavaScriptCore
import Testing

@testable import TakeShotKit

/// The multiview stream, driven the way a phone drives it: the page over
/// HTTP, the subscription over the socket, and JPEG frames that came off the
/// mock backend's real display path. The backpressure suites below assert the
/// two rules the stream lives by — one frame in flight per client, and
/// latest-wins behind it.
@Suite @MainActor struct RemoteMultiviewTests {
    // MARK: - the page

    @Test func theCamerasPageIsServedAtItsRoute() async throws {
        try await ControllerHarness.run { controller, _ in
            let (port, _) = try await RemoteHarness.serve(controller)
            let url = try #require(URL(
                string: "http://127.0.0.1:\(port)\(RemotePage.camerasPath)"))
            let (data, response) = try await RemoteHarness.session().data(from: url)
            let http = try #require(response as? HTTPURLResponse)

            #expect(http.statusCode == 200)
            #expect(http.value(forHTTPHeaderField: "Content-Type")
                == "text/html; charset=utf-8")
            let html = try #require(String(bytes: data, encoding: .utf8))
            #expect(html.contains("<!doctype html>"))
            #expect(html.contains(L("cameras_title")))
            #expect(!html.contains(RemotePage.configToken))
        }
    }

    // MARK: - the frames, end to end

    /// The whole feature: a phone that showed the PIN and asked for frames is
    /// handed real JPEGs of the signal the mock backend is generating — the
    /// right camera byte in front, the promised downscale behind it.
    @Test func anAuthenticatedClientReceivesADownscaledJPEGFrame() async throws {
        try await ControllerHarness.run(live: true) { controller, _ in
            await ControllerWait.until { controller.signalFormat != nil }
            let (port, pin) = try await RemoteHarness.serve(controller)
            let client = try await RemoteHarness.connect(
                port: port, pin: pin, session: RemoteHarness.session())
            defer { client.close() }
            _ = try await client.next(type: "auth")

            // The status names the cameras the tiles will label themselves
            // with — the main camera, recording nothing yet.
            let status = try await client.next(type: "status")
            let cameras = try #require(status["cameras"] as? [[String: Any]])
            #expect(cameras.count == 1)
            #expect(cameras.first?["name"] as? String
                == controller.settings.naming.cameraLabel)
            #expect(cameras.first?["recording"] as? Bool == false)

            // Nothing is encoded until somebody asks: the subscription is
            // what builds the encoder at all.
            #expect(controller.remoteMultiviewEncoder == nil)
            try await client.send(["action": "multiview", "on": true,
                                   "pin": pin])

            let frame = try await client.nextFrame()
            #expect(frame.count > RemoteClient.frameHeaderBytes)
            #expect(frame.first == 0, "the main camera is index 0")
            let jpeg = Data(frame.dropFirst(RemoteClient.frameHeaderBytes))
            #expect(jpeg.prefix(2) == Data([0xFF, 0xD8]),
                    "the payload does not start like a JPEG")
            let image = try #require(NSBitmapImageRep(data: jpeg),
                                     "the frame bytes do not decode")
            // 1080p25 from the mock, one camera — so the tile is the whole
            // phone and gets the top rung of the ladder.
            #expect(image.pixelsWide == 1280)
            #expect(image.pixelsHigh == 720)

            // And the demand edge did its half: the encoder exists now.
            #expect(controller.remoteMultiviewEncoder != nil)
        }
    }

    /// The stream is production picture and sits behind the PIN like the
    /// status does: a wrong code gets no frames — and never even starts the
    /// encoder, so a guesser cannot cost the recorder encode work either.
    @Test func theWrongPINGetsNoFramesAndStartsNoEncoder() async throws {
        try await ControllerHarness.run(live: true) { controller, _ in
            await ControllerWait.until { controller.signalFormat != nil }
            let (port, pin) = try await RemoteHarness.serve(controller)
            let wrong = RemoteHarness.wrongPIN(besides: pin)
            let client = try await RemoteHarness.connect(
                port: port, pin: wrong, session: RemoteHarness.session())
            defer { client.close() }
            #expect(try await client.next(type: "auth")["ok"] as? Bool == false)

            try await client.send(["action": "multiview", "on": true,
                                   "pin": wrong])
            #expect(try await client.next(type: "auth")["ok"] as? Bool == false)

            // The refusal has to hold over time, so this is the full-budget
            // wait that proves a change did NOT happen.
            _ = await ControllerWait.until(
                { controller.remoteMultiviewEncoder != nil },
                timeout: .seconds(2))
            #expect(controller.remoteMultiviewEncoder == nil,
                    "a wrong PIN was enough to start the multiview encoder")
            #expect(controller.remoteServer?.multiviewFrameSends == 0,
                    "a frame went to a client that never authenticated")
        }
    }

    /// The same thing again against a controller with the operator's tooling
    /// switched on — punch-in at 2x and every assist lit.
    ///
    /// Which half of the claim this can carry is worth being exact about. The
    /// routing — the grid is handed the clean frame, byte for byte, with a
    /// wipe running, the key on and every aid lit — is pinned deterministically
    /// in `PreviewDisplayPathTests.theCameraGridGetsTheCleanFrameAndNotTheOperatorsView`,
    /// against known pixels the synthetic source here cannot offer. What this
    /// adds is the end of the wire: with all of it on, frames still flow, the
    /// tile is still the whole signal (a 2x desqueeze would halve its height),
    /// and the buffer behind it is still full frame — which is the punch-in's
    /// crop not having happened.
    @Test func punchInAndTheAssistsDoNotReachThePhone() async throws {
        try await ControllerHarness.run(live: true) { controller, _ in
            await ControllerWait.until { controller.signalFormat != nil }
            controller.setAssist {
                $0.colorTool = .falseColor
                $0.zebraOn = true
                $0.peakingOn = true
                $0.desqueeze = 2
                $0.setPunchIn(2)
            }
            try #require(controller.assist.punchIn == 2,
                         "the fixture never switched the punch-in on")
            try #require(controller.assist.anyToolActive)

            let (port, pin) = try await RemoteHarness.serve(controller)
            let client = try await RemoteHarness.connect(
                port: port, pin: pin, session: RemoteHarness.session())
            defer { client.close() }
            _ = try await client.next(type: "auth")
            try await client.send(["action": "multiview", "on": true,
                                   "pin": pin])

            let frame = try await client.nextFrame()
            let jpeg = Data(frame.dropFirst(RemoteClient.frameHeaderBytes))
            let image = try #require(NSBitmapImageRep(data: jpeg),
                                     "the frame bytes do not decode")
            // 1080p25 whole, scaled to the ceiling — the same numbers the
            // assist-free test above asserts.
            #expect(image.pixelsWide == 1280)
            #expect(image.pixelsHigh == 720, "the desqueeze reshaped the tile")
            // The frame the grid is fed is the pipeline's clean one, and it is
            // the whole signal: a punch-in applied here would have cropped it
            // to a quarter of the area before the encoder ever saw it.
            let clean = try #require(controller.pipeline.currentPreviewBuffer())
            #expect(CVPixelBufferGetWidth(clean) == 1920,
                    "the punch-in cropped the frame the grid encodes")
            #expect(CVPixelBufferGetHeight(clean) == 1080)
        }
    }

    // MARK: - backpressure

    /// THE one-in-flight rule: while a frame's completion has not landed, the
    /// next one is held — not handed to a transport that would buffer it
    /// without limit. The client is a raw socket that never reads, and the
    /// frames are pushed straight at the server: what is being measured is
    /// the send ledger, not the encoder.
    @Test func aSecondFrameIsNotSentWhileTheFirstIsInFlight() async throws {
        try await ControllerHarness.run { controller, _ in
            let (port, pin) = try await RemoteHarness.serve(controller)
            let server = try #require(controller.remoteServer)

            let stalled = try RemoteRawSocket(port: port)
            defer { stalled.close() }
            try stalled.handshake()
            stalled.sendHello(pin: pin)
            stalled.sendFrame(opcode: 0x1, payload: Data(
                #"{"action":"multiview","on":true,"pin":"\#(pin)"}"#.utf8))
            // The demand edge proves the subscription registered: the encoder
            // only exists once a subscribed client does.
            let subscribed = await ControllerWait.until {
                controller.remoteMultiviewEncoder != nil
            }
            try #require(subscribed, "the raw socket never subscribed")

            // Push until a frame is held behind one in flight. Half-
            // megabyte frames because loopback buffers absorb small sends for
            // most of a minute, and the frame path has no in-flight BYTE
            // ceiling to trip (frames are deliberately not counted into
            // `inFlightBytes` — see RemoteClient+Multiview), so a big frame
            // here cannot drop the client the way it could on the status
            // path. One push per round, NOT a burst — a burst collapses under
            // latest-wins into two sends total, which is the very rule under
            // test working against its own fixture.
            let big = Data(repeating: 0xAB, count: 512 * 1024)
            let backedUp: Bool = await Self.backUp(server, jpeg: big)
            try #require(backedUp,
                         "the socket never backed up, so nothing was held")
            let settled: Int = server.multiviewFrameSends

            // The claim itself: more frames arrive, none is handed over while
            // the one in flight is unacknowledged — and per camera they
            // REPLACE the held frame instead of queueing behind it.
            for _ in 0..<Self.floodFrames {
                server.broadcastFrame(camera: 0, jpeg: big)
                server.broadcastFrame(camera: 1, jpeg: big)
            }
            // Poll for the VIOLATION rather than for quiet: a gate that
            // stopped working puts the whole flood on the wire in the time it
            // takes the queue to drain the pushes.
            _ = await ControllerWait.until(
                { server.multiviewFrameSends > settled + Self.acknowledgeSlack },
                timeout: .seconds(2))

            // The client has to still be there, or every ledger below reads
            // zero and the bounds pass without measuring anything.
            #expect(server.clientCount == 1, "the fixture's socket went away")
            #expect(server.multiviewFrameSends <= settled + Self.acknowledgeSlack,
                    "frames were handed over while one was in flight")
            #expect(server.multiviewPendingFrames <= 2,
                    "held frames queued up instead of latest-wins per camera")
        }
    }

    /// Frames pushed per camera by the flood. Twenty in total, against a
    /// tolerance of two, is the order of magnitude the claim rests on.
    private static let floodFrames: Int = 10

    /// How far the send ledger may move during the flood and still be obeying
    /// the rule.
    ///
    /// It is not zero, and asserting zero is what made this CI's flake. A
    /// socket whose window is shutting can still acknowledge the frame already
    /// on the wire, and each acknowledgement releases exactly one held frame —
    /// so the ledger moves by one, twice over at the worst, with nothing wrong.
    /// The runner's red run moved it by exactly one, between the wedge check
    /// and the assertion; the same failure reproduces on the development Mac,
    /// verbatim, by returning from `backUp` one round early.
    ///
    /// Two is a tenth of what the flood pushes, so the distance the assertion
    /// actually keeps is the whole one: a gate that stopped working shows up
    /// as twenty, not as three.
    private static let acknowledgeSlack: Int = 2

    /// Feed one camera until the socket is backed up: a frame handed to the
    /// transport and another HELD behind it. One frame per round, so
    /// latest-wins cannot collapse the flood into two sends.
    ///
    /// Both halves of the exit are outcomes the ledger states, and that is the
    /// whole repair. This used to decide the socket was wedged from 300 ms of
    /// quiet, and no window can carry that claim: an unacknowledged frame and
    /// a shut window look identical inside one, so on a slower machine the
    /// check passed with a completion still on its way, it landed during the
    /// flood, and the ledger the assertions read had moved under them. That is
    /// the runner's red run, and it reproduces here — verbatim, three times in
    /// three — by returning from this function one round early.
    ///
    /// A held frame is also the only fixture the assertions need now, which is
    /// why nothing here waits for the socket to be permanently stuck.
    @MainActor
    private static func backUp(_ server: RemoteServer,
                               jpeg: Data) async -> Bool {
        for _ in 0..<1024 {
            server.broadcastFrame(camera: 0, jpeg: jpeg)
            // Reading the ledger is a `sync` hop onto the server's own queue,
            // so the push above has already been applied when this runs.
            if server.multiviewFramesInFlight == 1,
               server.multiviewPendingFrames >= 1 { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    /// A phone that walked out of Wi-Fi mid-stream holds one frame in flight
    /// and one pending per camera — and nothing else. The tablet next to it
    /// keeps its status pushes and its own frames.
    @Test func aStalledMultiviewClientDoesNotBreakTheOthers() async throws {
        try await ControllerHarness.run { controller, root in
            try RemoteHarness.seedTake(controller, in: root, named: "A001C21",
                                       clip: 21)
            let (port, pin) = try await RemoteHarness.serve(controller)
            let server = try #require(controller.remoteServer)

            let healthy = try await RemoteHarness.connect(
                port: port, pin: pin, session: RemoteHarness.session())
            defer { healthy.close() }
            _ = try await healthy.next(type: "auth")
            try await healthy.send(["action": "multiview", "on": true,
                                    "pin": pin])

            // The healthy client drains for the whole test — statuses AND
            // frames — remembering what got through, and saying so itself if
            // its own socket is the one that goes (see `RemoteDrain`, and the
            // stalled-client status test for why the drain must never stop
            // reading).
            let drain = RemoteDrain(healthy)
            defer { drain.stop() }

            let stalled = try RemoteRawSocket(port: port)
            defer { stalled.close() }
            try stalled.handshake()
            stalled.sendHello(pin: pin)
            stalled.sendFrame(opcode: 0x1, payload: Data(
                #"{"action":"multiview","on":true,"pin":"\#(pin)"}"#.utf8))
            let joined = await ControllerWait.until { server.clientCount == 2 }
            try #require(joined, "the raw socket never authenticated")

            // Enough frame bytes to wedge the stalled socket, paced by the
            // reading client's RECEIPT — a burst would collapse under
            // latest-wins into two sends, and the healthy client's stream is
            // the thing being asserted alive round after round.
            let big = Data(repeating: 0xCD, count: 512 * 1024)
            for round in 1...12 {
                server.broadcastFrame(camera: 0, jpeg: big)
                let got = await ControllerWait.until {
                    drain.binaries.value >= round
                }
                #expect(got, "the reading client lost its frame stream")
            }

            // The stalled client holds its bounded slot — frames never count
            // against the status ledger, so it is not dropped for them...
            #expect(server.clientCount == 2)

            // ...and the status stream flows past it exactly as before.
            controller.takes[0].rating = .bad
            controller.pushRemoteStatus()
            let heard = await ControllerWait.until { drain.badRatings.value > 0 }
            #expect(heard, "a stalled multiview client cost the others their status")
        }
    }
}

/// The wire pieces on their own, like `RemoteProtocolTests`: the page, the
/// subscription message and the camera list in the status.
@Suite struct RemoteMultiviewProtocolTests {
    @Test func aMultiviewSubscriptionParses() throws {
        let on = try #require(RemoteMessage.parse(
            #"{"action":"multiview","on":true,"pin":"0417"}"#))
        #expect(on.command == .multiview(on: true))
        #expect(on.pin == "0417")
        let off = try #require(RemoteMessage.parse(
            #"{"action":"multiview","on":false,"pin":"0417"}"#))
        #expect(off.command == .multiview(on: false))
        // A missing flag must not be read as "on".
        #expect(RemoteMessage.parse(#"{"action":"multiview","pin":"1"}"#) == nil)
    }

    /// The camera list the tiles are built from: main first, each with its
    /// OWN recording state — in multicam the boards record apart.
    @Test func theStatusJSONCarriesTheCameraGrid() throws {
        var status = RemoteStatus()
        status.cameras = [RemoteStatus.CameraState(name: "A", recording: true),
                          RemoteStatus.CameraState(name: "B", recording: false)]
        let object = try #require(try JSONSerialization.jsonObject(
            with: Data(status.json.utf8)) as? [String: Any])
        let cameras = try #require(object["cameras"] as? [[String: Any]])
        #expect(cameras.count == 2)
        #expect(cameras[0]["name"] as? String == "A")
        #expect(cameras[0]["recording"] as? Bool == true)
        #expect(cameras[1]["name"] as? String == "B")
        #expect(cameras[1]["recording"] as? Bool == false)
    }

    /// The page parses and carries its labels in both languages — the same
    /// guard the other two pages have, for the same blank-phone failure.
    @Test @MainActor func theCamerasPageCarriesItsLabelsAndParses() throws {
        for language in [AppLanguage.english, .russian] {
            let served = ViewRender.withLanguage(language) {
                RemotePage.camerasHTML()
            }
            let html = try #require(String(bytes: served, encoding: .utf8))
            let title = ViewRender.withLanguage(language) { L("cameras_title") }
            #expect(!html.contains(RemotePage.configToken),
                    "\(language.rawValue): the config token was not replaced")
            #expect(html.contains(title),
                    "\(language.rawValue): the page is missing its labels")
            // Self-contained: nothing is fetched from anywhere.
            #expect(!html.contains("src=\"http"))
            #expect(!html.contains("<link "))

            let open = try #require(html.range(of: "<script>"))
            let close = try #require(html.range(of: "</script>"))
            let context = try #require(JSContext())
            context.setObject(String(html[open.upperBound..<close.lowerBound]),
                              forKeyedSubscript: "SOURCE" as NSString)
            context.evaluateScript("new Function(SOURCE)")
            #expect(context.exception == nil,
                    "\(language.rawValue): \(context.exception?.toString() ?? "")")
        }
    }

    /// The gate's labels are painted, not merely injected. This page shipped
    /// with an unlabelled PIN field and a blank Connect button — the strings
    /// were in the config object and nothing ever read them.
    @Test @MainActor func theCameraPagePaintsItsGate() throws {
        let html = try #require(String(bytes: RemotePage.camerasHTML(),
                                       encoding: .utf8))
        #expect(html.contains("S.pinPrompt"), "the gate has no prompt")
        #expect(html.contains("S.connect"), "the connect button has no label")
        #expect(html.contains("paintLabels()"))
    }

    /// The way OUT of a fullscreen tile.
    ///
    /// There was none. The tap handler refused BOTH directions on
    /// `tiles.length < 2`, and the count really does drop to one under a tile
    /// that is already fullscreen — a board leaving the multicam set pops the
    /// OTHER tile (`ensureTiles` pops from the end). The remaining tile kept the
    /// `full` class, which is `position: fixed; inset: 0`, so it covered the
    /// footer with the timecode and the connection dot, and the only way back
    /// was to reload the page. On a phone gaffer-taped to a cart, that is the
    /// monitoring surface gone.
    ///
    /// Driven rather than pattern-matched: the rule is a pure function in the
    /// shipped page, and this evaluates THAT text in a JS engine. Entering is
    /// still refused for a single tile — it is already the whole screen — and
    /// leaving never is.
    @Test @MainActor func aFullscreenCameraTileCanAlwaysBeLeft() throws {
        let html: String = try #require(
            String(bytes: RemotePage.camerasHTML(), encoding: .utf8))
        let name: String = "function wantsFullscreen("
        let start: Range<String.Index> = try #require(
            html.range(of: name),
            "the cameras page states no fullscreen rule to check")
        let end: Range<String.Index> = try #require(
            html.range(of: "\n}", range: start.upperBound..<html.endIndex),
            "the fullscreen rule does not end where this test can cut it")
        let source: String = String(html[start.lowerBound..<end.upperBound])
        let context: JSContext = try #require(JSContext())
        context.evaluateScript(source)
        try #require(context.exception == nil,
                     "the fullscreen rule does not evaluate on its own")

        let asks: (Bool, Int) -> Bool = { wasFull, count in
            context.evaluateScript(
                "wantsFullscreen(\(wasFull), \(count))")?.toBool() ?? false
        }
        // The way out, at every count — including the one the old guard refused.
        #expect(!asks(true, 1), "a lone fullscreen tile cannot be left")
        #expect(!asks(true, 2), "a fullscreen tile cannot be left")
        #expect(!asks(true, 4))
        // The way in, only where it means something.
        #expect(!asks(false, 1), "one tile is already the whole screen")
        #expect(asks(false, 2))
        #expect(asks(false, 4))

        // The guard that refused the exit tap is gone, and the tap asks the rule
        // rather than carrying a second copy of it.
        #expect(!html.contains("if (tiles.length < 2) { return; }"),
                "the tap handler still refuses to leave fullscreen")
        #expect(html.contains("if (wantsFullscreen(was, tiles.length))"),
                "the tap handler does not ask the rule")
        // …and a grid that shrinks under a fullscreen tile corrects itself, so
        // the operator is not left having to find the tap at all.
        #expect(html.contains("if (want < 2) { clearFullscreen(); }"),
                "a shrinking grid leaves a lone tile fullscreen")
    }

    @Test @MainActor func everyCamerasLabelIsTranslated() {
        for (field, key) in RemotePage.camerasLabels {
            for language in [AppLanguage.english, AppLanguage.russian] {
                let value = ViewRender.withLanguage(language) { L(key) }
                #expect(value != key,
                        "\(field) renders as its raw key in \(language.rawValue)")
            }
        }
    }
}

extension RemoteTestClient {
    /// The next binary message — a multiview frame — skipping the statuses
    /// interleaved with it. Bounded, like `next(type:)`, so a stream that
    /// never starts fails the test instead of hanging the suite.
    func nextFrame(within attempts: Int = 40) async throws -> Data {
        for _ in 0..<attempts {
            if case .data(let data) = try await task.receive() { return data }
        }
        Issue.record("no binary frame arrived")
        return Data()
    }
}
