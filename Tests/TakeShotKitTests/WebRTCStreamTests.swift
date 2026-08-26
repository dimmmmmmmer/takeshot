import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// A viewer's slot comes back whether or not the browser ever connects.
///
/// The cap on viewers is only a defence if slots are returned, and a WebRTC
/// connection that never completes does not announce itself for half a minute
/// or more. Its own suite because it needs no encoder: the deadline is a clock
/// and a flag, and it has to hold on a machine that cannot encode H.264 too.
@Suite struct WebRTCViewerDeadlineTests {
    private final class Reports: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [WebRTCViewer.Event] = []
        func record(_ event: WebRTCViewer.Event) {
            lock.withLock { stored.append(event) }
        }

        var all: [WebRTCViewer.Event] { lock.withLock { stored } }
    }

    private func viewer(deadline: TimeInterval, reports: Reports)
        -> (WebRTCViewer, FakeWebRTCPeer) {
        let plan = WebRTCOffer.VideoPlan(mid: "0", payloadType: 119,
                                         formatParameters: "")
        let peer = FakeWebRTCPeer(plan: plan, ssrc: 7)
        let encoder = LiveVideoEncoder(bitsPerSecond: 1_000_000)
        return (WebRTCViewer(peer: peer, plan: plan, ssrc: 7,
                             picture: .decorated, encoder: encoder,
                             connectDeadline: deadline) { reports.record($0) },
                peer)
    }

    /// A viewer that never connects gives its slot back.
    @Test func aViewerThatNeverConnectsIsGivenUpOn() async throws {
        let reports = Reports()
        let (live, _) = viewer(deadline: 0.05, reports: reports)
        #expect(await ControllerWait.untilWritten {
            reports.all.contains(.gone)
        }, "the deadline never fired")
        live.stop()
    }

    /// And one that DID connect is left alone — the deadline is about a slot
    /// nobody is using, not a session with a picture in it.
    @Test func aConnectedViewerIsNotGivenUpOn() async throws {
        let reports = Reports()
        let (live, peer) = viewer(deadline: 0.3, reports: reports)
        peer.report(.connected)
        #expect(await ControllerWait.untilWritten {
            reports.all.contains(.connected)
        })
        try await Task.sleep(for: .milliseconds(600))
        #expect(!reports.all.contains(.gone),
                "a connected viewer was dropped by the deadline")
        live.stop()
    }
}

/// The end-to-end claim this whole wave rests on: **one encoder, two wire
/// formats.**
///
/// A frame off the board is compressed ONCE and reaches the SRT link as a
/// transport stream and the browser as RTP, from the same session. Two
/// `VTCompressionSession`s doing the same 1080p picture on a machine that is
/// writing ProRes to a card is the cost this design exists to avoid, and the
/// only way to show it is not being paid is to watch both wires move off one
/// encoder.
///
/// Gated on a real H.264 encoder, like the SRT frame-path suites: everything
/// here drives VideoToolbox, and a machine that cannot encode would be
/// reporting the machine.
@Suite(.enabled(if: SRTVideoEncoder.isSupported,
                "no H.264 encoder on this machine"))
@MainActor
struct WebRTCStreamTests {
    /// One shared encoder feeds the SRT link and a browser at the same time.
    @Test func oneEncoderFeedsBothTheLinkAndTheBrowser() async throws {
        let streams = SRTStreamLog()
        let peers = WebRTCPeerLog()
        try await ControllerHarness.run(live: true) { controller, _ in
            controller.mirrors.srtStreamFactory = { streams.build($0) }
            controller.mirrors.webrtcPeerFactory = { peers.build($0, $1) }
            controller.settings.srt.address = "10.0.0.9"
            controller.settings.srt.enabled = true
            let encoder: LiveVideoEncoder =
                try #require(controller.mirrors.liveEncoders[.decorated],
                             "the switch built no encoder")
            let served = try await RemoteHarness.serve(controller)

            let reply = try await WebRTCHarness.offer(port: served.port,
                                                      pin: served.pin)
            #expect(reply.status == 200)
            // THE assertion: the browser joined the session that was already
            // running rather than starting one of its own.
            #expect(controller.mirrors.liveEncoders[.decorated] === encoder,
                    "answering an offer replaced the shared encoder")
            #expect(controller.mirrors.liveEncoders.count == 1,
                    "a viewer on the same picture built a second session")

            let peer: FakeWebRTCPeer = try #require(peers.latest)
            peer.report(.connected)
            let stream: FakeSRTStream = try #require(streams.latest)
            #expect(await ControllerWait.untilWritten {
                !peer.packets.isEmpty && !stream.datagrams.isEmpty
            }, "RTP \(peer.packets.count), TS \(stream.datagrams.count)")
            // Same picture, two wires: transport packets on one, RTP on the
            // other, both carrying what the browser's offer negotiated.
            #expect(stream.datagrams.allSatisfy {
                $0.count == MPEGTSMuxer.datagramLength
            })
            let first = RTPFixtures.parse(try #require(peer.packets.first))
            #expect(first.version == 2)
            #expect(first.payloadType == 119)
            #expect(first.ssrc == peer.ssrc)
        }
    }

    /// The browser's first packet is the start of a picture, never the middle
    /// of one.
    ///
    /// A viewer that joined mid-GOP would be sent slices with no parameter sets
    /// in front of them — a black rectangle the browser answers with a PLI. The
    /// join asks for a keyframe (`SRTVideoEncoder.requestKeyframe`, which is
    /// what it was added for) and the viewer holds everything back until one
    /// arrives, so the two together make this a fact rather than a race.
    ///
    /// The offer is deliberately made LATE — after the SRT link has been
    /// carrying frames for a while — because a viewer that joins on frame one
    /// gets a keyframe whether anything asked for one or not.
    @Test func theBrowsersFirstPacketsCarryTheParameterSets() async throws {
        let streams = SRTStreamLog()
        let peers = WebRTCPeerLog()
        try await ControllerHarness.run(live: true) { controller, _ in
            controller.mirrors.srtStreamFactory = { streams.build($0) }
            controller.mirrors.webrtcPeerFactory = { peers.build($0, $1) }
            controller.settings.srt.address = "10.0.0.9"
            controller.settings.srt.enabled = true
            let served = try await RemoteHarness.serve(controller)
            let stream: FakeSRTStream = try #require(streams.latest)
            // Well past one keyframe interval, so the session is mid-GOP.
            #expect(await ControllerWait.untilWritten {
                stream.datagrams.count > 40
            }, "the link never got going")

            _ = try await WebRTCHarness.offer(port: served.port,
                                              pin: served.pin)
            let peer: FakeWebRTCPeer = try #require(peers.latest)
            peer.report(.connected)
            #expect(await ControllerWait.untilWritten { !peer.packets.isEmpty })
            // Enough packets to hold a whole access unit, then read back what
            // the browser would have reassembled first.
            try await Task.sleep(for: .milliseconds(300))
            let units: [[UInt8]] = RTPFixtures.reassemble(peer.packets)
            let types: [UInt8] = units.compactMap { $0.first.map { $0 & 0x1F } }
            #expect(types.contains(7), "no SPS in \(types.prefix(8))")
            #expect(types.contains(8), "no PPS in \(types.prefix(8))")
            // And the SPS is at the very front: everything before the first
            // keyframe is held back, so there is no slice ahead of it.
            let firstSlice: Int = types.firstIndex(where: { $0 == 1 || $0 == 5 })
                ?? types.count
            let sps: Int = try #require(types.firstIndex(of: 7))
            #expect(sps < firstSlice, "a slice went out ahead of the SPS")
        }
    }

    /// The packetizing and the sending happen on the viewer's own queue.
    ///
    /// Never the capture queue, which owns the per-frame work; and never the
    /// shared encoder's, where one phone's socket would pace every other
    /// consumer on it — which is the whole reason the fan-out hops.
    @Test func theSendNeverRunsOnTheEncodersQueue() async throws {
        let peers = WebRTCPeerLog()
        try await ControllerHarness.run(live: true) { controller, _ in
            controller.mirrors.webrtcPeerFactory = { peers.build($0, $1) }
            let served = try await RemoteHarness.serve(controller)
            _ = try await WebRTCHarness.offer(port: served.port, pin: served.pin)
            let peer: FakeWebRTCPeer = try #require(peers.latest)
            peer.report(.connected)
            #expect(await ControllerWait.untilWritten { !peer.queues.isEmpty },
                    "no RTP ever reached the peer")
            #expect(peer.queues.allSatisfy { $0 == WebRTCViewer.queueLabel },
                    "the send ran on \(Set(peer.queues))")
        }
    }

    /// A browser watching keeps the encoder alive across the SRT switch going
    /// off, and the last one out takes it down.
    ///
    /// Both halves matter and they fail differently: without the first, an
    /// operator switching SRT off blacks out every phone; without the second,
    /// an idle set encodes 1080p forever for nobody.
    @Test func theLastOneOutDropsTheEncoder() async throws {
        let peers = WebRTCPeerLog()
        try await ControllerHarness.run(live: true) { controller, _ in
            controller.mirrors.webrtcPeerFactory = { peers.build($0, $1) }
            controller.settings.srt.address = "10.0.0.9"
            controller.settings.srt.enabled = true
            let served = try await RemoteHarness.serve(controller)
            _ = try await WebRTCHarness.offer(port: served.port, pin: served.pin)
            let encoder: LiveVideoEncoder =
                try #require(controller.mirrors.liveEncoders[.decorated])

            controller.settings.srt.enabled = nil
            #expect(controller.mirrors.srt == nil)
            #expect(controller.mirrors.liveEncoders[.decorated] === encoder,
                    "switching SRT off blacked out the browser")

            let peer: FakeWebRTCPeer = try #require(peers.latest)
            peer.report(.failed)
            #expect(await ControllerWait.until {
                controller.mirrors.liveEncoders.isEmpty
            }, "the encoder outlived the last viewer")
            #expect(await ControllerWait.until { peer.isClosed })
            #expect(controller.mirrors.webrtcViewers.isEmpty)
        }
    }

    /// **The operator's bitrate dial still reaches the encoder, and without a
    /// rebuild.**
    ///
    /// This is the one thing the shared session could quietly have cost. The
    /// rate used to be fixed when the SRT mirror built its own encoder, so a
    /// change meant a new link and a new session; with one session serving
    /// everybody a rebuild is a gap and a keyframe for every browser at once,
    /// and — worse — a rate edit made while the SRT switch is OFF would have
    /// reached nothing at all, because nothing would have rebuilt.
    @Test func theBitrateDialReachesTheSharedSessionWithoutRebuildingIt()
        async throws {
        let peers = WebRTCPeerLog()
        try await ControllerHarness.run(live: true) { controller, _ in
            controller.mirrors.webrtcPeerFactory = { peers.build($0, $1) }
            controller.settings.srt.bitrateMbps = 6
            let served = try await RemoteHarness.serve(controller)
            _ = try await WebRTCHarness.offer(port: served.port, pin: served.pin)
            let encoder: LiveVideoEncoder =
                try #require(controller.mirrors.liveEncoders[.decorated])
            let peer: FakeWebRTCPeer = try #require(peers.latest)
            peer.report(.connected)
            #expect(await ControllerWait.untilWritten {
                encoder.appliedBitsPerSecond != nil
            }, "the session never started")
            #expect(encoder.appliedBitsPerSecond == 6_000_000)

            // The SRT switch is OFF throughout: the only thing watching is a
            // browser, and the dial has to reach it anyway.
            #expect(controller.mirrors.srt == nil)
            controller.settings.srt.bitrateMbps = 2
            #expect(await ControllerWait.untilWritten {
                encoder.appliedBitsPerSecond == 2_000_000
            }, "the session is at \(encoder.appliedBitsPerSecond ?? -1)")
            // Same session, not a new one — a rebuild is what this avoids.
            #expect(controller.mirrors.liveEncoders[.decorated] === encoder)
        }
    }

    /// The remote server going down takes every viewer with it. There is no
    /// other way to reach the app, so a connection left up would be a picture
    /// going to a page that can no longer offer, rate or stop anything.
    @Test func stoppingTheServerStopsEveryViewer() async throws {
        let peers = WebRTCPeerLog()
        try await ControllerHarness.run { controller, _ in
            controller.mirrors.webrtcPeerFactory = { peers.build($0, $1) }
            let served = try await RemoteHarness.serve(controller)
            _ = try await WebRTCHarness.offer(port: served.port, pin: served.pin)
            #expect(controller.mirrors.webrtcViewers.count == 1)
            controller.stopRemoteServer()
            #expect(controller.mirrors.webrtcViewers.isEmpty)
            #expect(controller.mirrors.liveEncoders.isEmpty)
            #expect(peers.latest?.isClosed == true)
        }
    }
}
