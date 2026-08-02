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

    @Test func theMultiviewPageIsServedAtItsRoute() async throws {
        try await ControllerHarness.run { controller, _ in
            let (port, _) = try await RemoteHarness.serve(controller)
            let url = try #require(URL(
                string: "http://127.0.0.1:\(port)\(RemotePage.multiviewPath)"))
            let (data, response) = try await RemoteHarness.session().data(from: url)
            let http = try #require(response as? HTTPURLResponse)

            #expect(http.statusCode == 200)
            #expect(http.value(forHTTPHeaderField: "Content-Type")
                == "text/html; charset=utf-8")
            let html = try #require(String(bytes: data, encoding: .utf8))
            #expect(html.contains("<!doctype html>"))
            #expect(html.contains(L("multiview_title")))
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
                == controller.settings.cameraLabel)
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
            // 1080p25 from the mock, long edge held to the encoder's ceiling.
            #expect(image.pixelsWide == 480)
            #expect(image.pixelsHigh == 270)

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

            // Push until the socket's window shuts and a completion stops
            // landing. Half-megabyte frames for the same reason the stalled-
            // client status test uses them: loopback buffers absorb small
            // sends for most of a minute. One push per round, NOT a burst — a
            // burst collapses under latest-wins into two sends total, which
            // is the very rule under test working against its own fixture.
            let big = Data(repeating: 0xAB, count: 512 * 1024)
            let stuck = await Self.wedge(server, jpeg: big)
            let settled = try #require(stuck, "the socket never stalled")

            // The claim itself: more frames arrive, none is handed over while
            // the one in flight is unacknowledged — and per camera they
            // REPLACE the held frame instead of queueing behind it.
            for _ in 0..<10 {
                server.broadcastFrame(camera: 0, jpeg: big)
                server.broadcastFrame(camera: 1, jpeg: big)
            }
            _ = await ControllerWait.until(
                { server.multiviewFrameSends > settled }, timeout: .seconds(2))
            #expect(server.multiviewFrameSends == settled,
                    "a second frame was sent while the first was in flight")
            #expect(server.multiviewFramesInFlight == 1)
            #expect(server.multiviewPendingFrames == 2,
                    "held frames queued up instead of latest-wins per camera")
        }
    }

    /// Feed frames until a completion stops landing, and hand back the send
    /// ledger at that point — nil when the socket never wedged inside the
    /// budget. One frame per round so latest-wins cannot collapse the flood,
    /// and the wedge is confirmed by the ledger holding still across a beat
    /// WITH a frame in flight — an outcome poll, never a wall-clock guess.
    @MainActor
    private static func wedge(_ server: RemoteServer,
                              jpeg: Data) async -> Int? {
        for _ in 0..<80 {
            server.broadcastFrame(camera: 0, jpeg: jpeg)
            try? await Task.sleep(for: .milliseconds(50))
            guard server.multiviewFramesInFlight == 1 else { continue }
            let before = server.multiviewFrameSends
            try? await Task.sleep(for: .milliseconds(300))
            if server.multiviewFrameSends == before,
               server.multiviewFramesInFlight == 1 {
                return before
            }
        }
        return nil
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
            // frames — remembering what got through (see the stalled-client
            // status test for why the drain must never stop reading).
            let sawBadRating = HitCounter()
            let framesSeen = HitCounter()
            let drain = Task { @MainActor in
                while true {
                    switch try await healthy.task.receive() {
                    case .data:
                        framesSeen.bump()
                    case .string(let text):
                        if text.contains(#""rating":"bad""#) {
                            sawBadRating.bump()
                        }
                    @unknown default:
                        break
                    }
                }
            }
            defer { drain.cancel() }

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
                    framesSeen.value >= round
                }
                #expect(got, "the reading client lost its frame stream")
            }

            // The stalled client holds its bounded slot — frames never count
            // against the status ledger, so it is not dropped for them...
            #expect(server.clientCount == 2)

            // ...and the status stream flows past it exactly as before.
            controller.takes[0].rating = .bad
            controller.pushRemoteStatus()
            let heard = await ControllerWait.until { sawBadRating.value > 0 }
            #expect(heard, "a stalled multiview client cost the others their status")
        }
    }
}

/// The encoder on its own: the downscale, the JPEG, and the pace — no server,
/// no socket, a known frame in and bytes out.
@Suite @MainActor struct MultiviewEncoderTests {
    /// What the sink was handed, lock-boxed off the encoder's queue.
    private final class FrameSink: @unchecked Sendable {
        private let lock = NSLock()
        private var frames: [(camera: Int, jpeg: Data)] = []

        func record(_ camera: Int, _ jpeg: Data) {
            lock.withLock { frames.append((camera, jpeg)) }
        }

        var count: Int { lock.withLock { frames.count } }
        var cameras: Set<Int> { lock.withLock { Set(frames.map(\.camera)) } }
    }

    /// The promised downscale: long edge to the ceiling, aspect kept, and a
    /// frame already smaller passes through unscaled.
    @Test func aFrameIsDownscaledToThePhoneCeiling() throws {
        let context = CIContext(options: [.cacheIntermediates: false])
        let wide = MediaFixtures.pixelBuffer(level: 0x60, width: 960,
                                             height: 540)
        let jpeg = try #require(MultiviewEncoder.jpeg(from: wide,
                                                      context: context))
        #expect(jpeg.prefix(2) == Data([0xFF, 0xD8]))
        let image = try #require(NSBitmapImageRep(data: jpeg))
        #expect(image.pixelsWide == 480)
        #expect(image.pixelsHigh == 270)

        let small = MediaFixtures.pixelBuffer(level: 0x60, width: 320,
                                              height: 180)
        let smallJPEG = try #require(MultiviewEncoder.jpeg(from: small,
                                                           context: context))
        let smallImage = try #require(NSBitmapImageRep(data: smallJPEG))
        #expect(smallImage.pixelsWide == 320,
                "a frame under the ceiling was upscaled")
    }

    /// Latest-wins under the pace: a burst of offers produces the first pass
    /// at once and at most ONE coalesced pass behind it — never a pass per
    /// offer, which is what would make a 25 fps wire cost 25 encodes.
    @Test func aBurstOfOffersCoalescesToThePace() async throws {
        let sink = FrameSink()
        let encoder = MultiviewEncoder { camera, jpeg in
            sink.record(camera, jpeg)
        }
        let frame = MediaFixtures.pixelBuffer(level: 0x60, width: 320,
                                              height: 180)
        for _ in 0..<25 { encoder.offer(frame, camera: 0) }

        let encoded = await ControllerWait.until { sink.count >= 1 }
        #expect(encoded, "nothing came out of the encoder")
        // Full-budget wait covering the pace interval with room to spare: the
        // burst may add one trailing pass and may never add a third.
        _ = await ControllerWait.until({ sink.count > 2 }, timeout: .seconds(2))
        #expect(sink.count <= 2,
                "25 offers in one burst encoded \(sink.count) times")
    }

    /// The cameras pace independently — B-cam's frames never wait out A-cam's
    /// interval.
    @Test func camerasAreEncodedIndependently() async throws {
        let sink = FrameSink()
        let encoder = MultiviewEncoder { camera, jpeg in
            sink.record(camera, jpeg)
        }
        let frame = MediaFixtures.pixelBuffer(level: 0x60, width: 320,
                                              height: 180)
        encoder.offer(frame, camera: 0)
        encoder.offer(frame, camera: 1)
        let both = await ControllerWait.until { sink.cameras == [0, 1] }
        #expect(both, "the second camera waited on the first one's pace")
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
    @Test @MainActor func theMultiviewPageCarriesItsLabelsAndParses() throws {
        for language in [AppLanguage.english, .russian] {
            let served = ViewRender.withLanguage(language) {
                RemotePage.multiviewHTML()
            }
            let html = try #require(String(bytes: served, encoding: .utf8))
            let title = ViewRender.withLanguage(language) { L("multiview_title") }
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

    @Test @MainActor func everyMultiviewLabelIsTranslated() {
        for (field, key) in RemotePage.multiviewLabels {
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
