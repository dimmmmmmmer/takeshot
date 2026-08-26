import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// **What a viewer costs, counted rather than argued.**
///
/// The rule this whole wave rests on is arithmetic, so it is asserted as
/// arithmetic: encode each DISTINCT picture at least one viewer is actually
/// asking for, and nothing else. Every case below is one row of that.
///
/// No H.264 encoder is needed for any of it — a `LiveVideoEncoder` is an object
/// whose `VTCompressionSession` is not built until a frame arrives — so this
/// suite runs on a machine that cannot encode, and it counts SESSIONS rather
/// than watching bytes. What the sessions then do with a frame is
/// `WebRTCStreamTests`' job.
@MainActor
struct LivePicturePoolTests {
    /// Nobody watching costs nothing at all.
    ///
    /// Three things have to be true at once and they fail differently: no
    /// session exists (so no `VTCompressionSession` and no bitrate), no grid
    /// composer exists (so no per-frame GPU pass), and — the one that would be
    /// invisible — the pipeline's display slot is empty, so the frame path does
    /// not even pair the two pictures up per frame.
    @Test func nothingIsWiredWhileNobodyIsWatching() async throws {
        try await ControllerHarness.run { controller, _ in
            _ = try await RemoteHarness.serve(controller)
            #expect(controller.mirrors.liveEncoders.isEmpty)
            #expect(controller.mirrors.gridComposer == nil)
            #expect(!controller.pipeline.publishesDisplayFrames,
                    "an idle app is still paying the display slot per frame")
            #expect(!controller.pipeline.publishesMonitorFrames)
        }
    }

    /// **A second viewer of a picture that is already going costs no encode.**
    ///
    /// The headline claim. Two browsers, one picture, one session — and the
    /// second viewer really is a second viewer, which is what the count on the
    /// registry is there to say.
    @Test func aSecondViewerOfTheSamePictureCostsNoSession() async throws {
        let peers = WebRTCPeerLog()
        try await ControllerHarness.run { controller, _ in
            controller.mirrors.webrtcPeerFactory = { peers.build($0, $1) }
            let served = try await RemoteHarness.serve(controller)
            _ = try await WebRTCHarness.offer(port: served.port, pin: served.pin,
                                              picture: .clean)
            #expect(controller.mirrors.liveEncoders.count == 1)
            let first: LiveVideoEncoder =
                try #require(controller.mirrors.liveEncoders[.clean])

            _ = try await WebRTCHarness.offer(port: served.port, pin: served.pin,
                                              picture: .clean)
            #expect(controller.mirrors.webrtcViewers.count == 2)
            #expect(controller.mirrors.liveEncoders.count == 1,
                    "the second viewer built a second session")
            #expect(controller.mirrors.liveEncoders[.clean] === first,
                    "the second viewer replaced the session")
        }
    }

    /// **A viewer of a DIFFERENT picture costs exactly one more, and it goes
    /// away with them.**
    ///
    /// The other half of the same claim, and the case the owner described: a DP
    /// on the decorated frame while a script supervisor watches the clean one.
    /// Both are served, and the second session is paid for only while the
    /// second person is there.
    @Test func aViewerOfAnotherPictureCostsOneMoreAndOnlyWhileTheyAreThere()
        async throws {
        let peers = WebRTCPeerLog()
        try await ControllerHarness.run { controller, _ in
            controller.mirrors.webrtcPeerFactory = { peers.build($0, $1) }
            let served = try await RemoteHarness.serve(controller)
            _ = try await WebRTCHarness.offer(port: served.port, pin: served.pin,
                                              picture: .decorated)
            _ = try await WebRTCHarness.offer(port: served.port, pin: served.pin,
                                              picture: .clean)
            #expect(Set(controller.mirrors.liveEncoders.keys)
                        == [.decorated, .clean])

            // The clean one leaves. Its session goes and the other stays.
            let clean: FakeWebRTCPeer = try #require(peers.latest)
            clean.report(.failed)
            #expect(await ControllerWait.until {
                Set(controller.mirrors.liveEncoders.keys) == [.decorated]
            }, "the second picture outlived its only viewer: \(controller.mirrors.liveEncoders.keys)")
        }
    }

    /// The grid is a picture like the other two, and it brings a composer with
    /// it — which exists only while it is being watched, for the same reason
    /// the session does. Nothing composes a 2-up mosaic for nobody.
    @Test func theGridPictureBringsItsComposerAndTakesItAway() async throws {
        let peers = WebRTCPeerLog()
        try await ControllerHarness.run { controller, _ in
            controller.mirrors.webrtcPeerFactory = { peers.build($0, $1) }
            let served = try await RemoteHarness.serve(controller)
            _ = try await WebRTCHarness.offer(port: served.port, pin: served.pin,
                                              picture: .grid)
            #expect(controller.mirrors.liveEncoders[.grid] != nil)
            #expect(controller.mirrors.gridComposer != nil,
                    "the grid picture was answered with nothing composing it")
            // And it rides the MONITOR tap rather than the viewer's — which is
            // what keeps the grid moving while the operator scrubs a take.
            #expect(controller.pipeline.publishesMonitorFrames)

            let peer: FakeWebRTCPeer = try #require(peers.latest)
            peer.report(.failed)
            #expect(await ControllerWait.until {
                controller.mirrors.gridComposer == nil
            }, "the composer outlived the last viewer of the grid")
            #expect(controller.mirrors.liveEncoders.isEmpty)
            #expect(!controller.pipeline.publishesMonitorFrames)
        }
    }

    /// The `/cameras` page and a browser watching the grid share the monitor
    /// tap, and neither takes it away from the other.
    ///
    /// They are two consumers of one picture, so the failure this guards
    /// against is a teardown: the phone page closing while a director is
    /// watching the video grid must not stop the frames, and it used to be one
    /// `setOnMultiviewFrame(nil)` away from doing exactly that.
    @Test func theTwoGridsShareOneTapAndNeitherClosesIt() async throws {
        let peers = WebRTCPeerLog()
        try await ControllerHarness.run { controller, _ in
            controller.mirrors.webrtcPeerFactory = { peers.build($0, $1) }
            let served = try await RemoteHarness.serve(controller)
            controller.setRemoteMultiviewActive(true)
            _ = try await WebRTCHarness.offer(port: served.port, pin: served.pin,
                                              picture: .grid)
            #expect(controller.pipeline.publishesMonitorFrames)

            // The JPEG page closes. The video grid is still watching.
            controller.setRemoteMultiviewActive(false)
            #expect(controller.remoteMultiviewEncoder == nil)
            #expect(controller.mirrors.gridComposer != nil)
            #expect(controller.pipeline.publishesMonitorFrames,
                    "the phone page closing took the video grid's frames away")

            // And the other way round: the browser goes, the page stays.
            controller.setRemoteMultiviewActive(true)
            let peer: FakeWebRTCPeer = try #require(peers.latest)
            peer.report(.failed)
            #expect(await ControllerWait.until {
                controller.mirrors.gridComposer == nil
            })
            #expect(controller.pipeline.publishesMonitorFrames,
                    "the browser leaving took the phone page's frames away")
        }
    }

    /// The SRT link's picture is a constant, not a setting — and it is the one
    /// that has always been on that wire.
    ///
    /// Asserted at the pool rather than at the mirror, because that is where a
    /// change would show: an SRT link that started taking the clean picture
    /// would build a session under a different key and stop sharing with the
    /// browsers on the decorated one.
    @Test func theSRTLinkTakesTheDecoratedPictureAndSharesItWithBrowsers()
        async throws {
        let streams = SRTStreamLog()
        let peers = WebRTCPeerLog()
        try await ControllerHarness.run { controller, _ in
            controller.mirrors.srtStreamFactory = { streams.build($0) }
            controller.mirrors.webrtcPeerFactory = { peers.build($0, $1) }
            controller.settings.srt.address = "10.0.0.9"
            controller.settings.srt.enabled = true
            #expect(CaptureController.srtPicture == .decorated)
            #expect(Set(controller.mirrors.liveEncoders.keys) == [.decorated])

            let served = try await RemoteHarness.serve(controller)
            _ = try await WebRTCHarness.offer(port: served.port, pin: served.pin,
                                              picture: .decorated)
            #expect(controller.mirrors.liveEncoders.count == 1,
                    "a browser on SRT's own picture built a second session")

            // A browser on a different picture does NOT disturb the link's.
            _ = try await WebRTCHarness.offer(port: served.port, pin: served.pin,
                                              picture: .grid)
            #expect(Set(controller.mirrors.liveEncoders.keys)
                        == [.decorated, .grid])
        }
    }

    /// The operator's one bitrate dial reaches EVERY session, including one
    /// built for a picture the operator cannot see anybody watching.
    ///
    /// Without this a phone that chose the clean picture would sit at whatever
    /// rate its session happened to be built with, and turning the dial down
    /// on a busy network would fix the decorated feed and nothing else.
    @Test func theBitrateDialReachesEverySession() async throws {
        let peers = WebRTCPeerLog()
        try await ControllerHarness.run { controller, _ in
            controller.mirrors.webrtcPeerFactory = { peers.build($0, $1) }
            controller.settings.srt.bitrateMbps = 6
            let served = try await RemoteHarness.serve(controller)
            _ = try await WebRTCHarness.offer(port: served.port, pin: served.pin,
                                              picture: .decorated)
            _ = try await WebRTCHarness.offer(port: served.port, pin: served.pin,
                                              picture: .clean)
            #expect(controller.mirrors.liveEncoders.count == 2)

            controller.settings.srt.bitrateMbps = 2
            // Read off the object rather than out of a running session: this
            // suite deliberately never starts one, so what is checked is that
            // the dial reached every entry in the pool.
            for (picture, encoder) in controller.mirrors.liveEncoders {
                #expect(encoder.wantedBitsPerSecond == 2_000_000,
                        "\(picture) is still at \(encoder.wantedBitsPerSecond)")
            }
        }
    }
}
