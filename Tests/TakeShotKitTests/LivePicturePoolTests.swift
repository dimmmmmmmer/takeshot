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

    /// The video grid's tap lives exactly as long as the grid does.
    ///
    /// There were TWO consumers of the monitor tap until the JPEG `/cameras`
    /// page was removed — that page's encoder and the composed grid — and the
    /// thing this guarded against was one of them closing the tap while the
    /// other was still watching. One is left, so what remains to hold is the
    /// simpler half: the tap opens with the grid and goes with it, and a
    /// browser that drops takes its own frames away and nothing else's.
    @Test func theGridsTapOpensAndClosesWithIt() async throws {
        let peers = WebRTCPeerLog()
        try await ControllerHarness.run { controller, _ in
            controller.mirrors.webrtcPeerFactory = { peers.build($0, $1) }
            let served = try await RemoteHarness.serve(controller)
            #expect(!controller.pipeline.publishesMonitorFrames,
                    "the tap is open with nobody watching")

            _ = try await WebRTCHarness.offer(port: served.port, pin: served.pin,
                                              picture: .grid)
            #expect(controller.mirrors.gridComposer != nil)
            #expect(controller.pipeline.publishesMonitorFrames,
                    "the grid is up and nothing is feeding it")

            let peer: FakeWebRTCPeer = try #require(peers.latest)
            peer.report(.failed)
            #expect(await ControllerWait.until {
                controller.mirrors.gridComposer == nil
            }, "the composer outlived the browser")
            #expect(await ControllerWait.until {
                !controller.pipeline.publishesMonitorFrames
            }, "an idle set is still paying for a tap")
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

    /// **Every session in the pool stamps against ONE clock.**
    ///
    /// The app-level half of `LiveClockTests`, and it needs saying here because
    /// the unit suite builds its own encoders and would stay green while the
    /// controller handed each one a clock of its own. What that costs is a
    /// viewer changing picture: the session it moves onto would number the same
    /// instant from ITS own zero, minutes lower, and the browser would stall on
    /// a timestamp from the past.
    ///
    /// Asked with two different instants on purpose — a private clock and a
    /// shared one both answer 0 for the first instant they are ever given, so a
    /// single reading proves nothing.
    @Test func everySessionStampsAgainstOneClock() async throws {
        let peers = WebRTCPeerLog()
        try await ControllerHarness.run { controller, _ in
            controller.mirrors.webrtcPeerFactory = { peers.build($0, $1) }
            let served = try await RemoteHarness.serve(controller)
            _ = try await WebRTCHarness.offer(port: served.port, pin: served.pin,
                                              picture: .decorated)
            let first: LiveVideoEncoder =
                try #require(controller.mirrors.liveEncoders[.decorated])
            // The first session starts the clock…
            #expect(first.ticks(at: 1000) == 0)

            // …and a second picture, chosen five minutes later, joins it.
            _ = try await WebRTCHarness.offer(port: served.port, pin: served.pin,
                                              picture: .clean)
            let second: LiveVideoEncoder =
                try #require(controller.mirrors.liveEncoders[.clean])
            #expect(second.ticks(at: 1300) == first.ticks(at: 1300),
                    "second \(second.ticks(at: 1300)) vs first \(first.ticks(at: 1300))")
            #expect(second.ticks(at: 1300) == 300 * Int64(MPEGTSMuxer.clockHz))
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

/// **A shared session that cannot be built has to be said somewhere the
/// operator is looking.**
///
/// VideoToolbox refusing to build a `VTCompressionSession` is not an SRT
/// problem, though it used to be reported as one: a browser on `/live`, the
/// NDI source and the hardware playout all ride the same encoder. With the SRT
/// switch off, the event was inert — the phone sat on a black page and the
/// only explanation was in a log nobody opens on a set.
@MainActor
struct LiveEncoderFailureReportTests {
    @Test func withSRTOffTheFailureReachesTheAppsErrorLine() async throws {
        try await ControllerHarness.run { controller, _ in
            #expect(controller.mirrors.srt == nil, "this case is the switch OFF")
            controller.lastError = nil
            controller.reportLiveEncoderFailure("no encoder on this machine")

            let shown = try #require(controller.lastError,
                                     "a shared session failed and nothing said so")
            #expect(shown.contains("no encoder on this machine"),
                    "the reason did not travel: \(shown)")
        }
    }

    /// With SRT on, the row an operator already watches for this feed says it,
    /// in SRT's own words — and it is not said twice.
    @Test func withSRTOnTheRowSaysItInSRTsOwnWords() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.settings.srt.enabled = true
            controller.settings.srt.address = "127.0.0.1"
            let started = await ControllerWait.until { controller.mirrors.srt != nil }
            #expect(started, "the SRT mirror never came up")

            controller.lastError = nil
            controller.reportLiveEncoderFailure("no encoder on this machine")
            #expect(controller.mirrors.srtState
                == .failed("no encoder on this machine"))
            let shown = try #require(controller.lastError)
            #expect(shown == L("srt_failed", "no encoder on this machine"),
                    "the failure was said twice, in two voices: \(shown)")
        }
    }
}

/// The controller's half of the settings-recovery rule: an operator whose whole
/// setup is back at defaults is TOLD, at the launch that found the damage.
@MainActor
struct ControllerSettingsRecoveryTests {
    @Test func alaunchThatFoundDamagedSettingsSaysSo() throws {
        let suite = "takeshot.recovery.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // Written the way the app writes it — the key is CaptureCore's own and
        // is not exported, so the damage is planted by corrupting a real save.
        CaptureSettings().save(to: defaults)
        let key = try #require(defaults.dictionaryRepresentation().keys
            .first { $0.contains("CaptureSettings") })
        defaults.set(Data("{ not settings".utf8), forKey: key)

        let controller = CaptureController(backends: [], defaults: defaults)
        #expect(controller.lastError == L("settings_unreadable"),
                "the reset went unmentioned: \(controller.lastError ?? "-")")
        #expect(defaults.data(forKey: CaptureSettings.unreadableKey) != nil,
                "the operator's copy was not kept")
    }

    /// A good configuration starts silently.
    @Test func anordinaryLaunchSaysNothing() throws {
        let suite = "takeshot.recovery.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        CaptureSettings().save(to: defaults)

        let controller = CaptureController(backends: [], defaults: defaults)
        #expect(controller.lastError == nil,
                "a clean launch complained: \(controller.lastError ?? "-")")
    }
}
