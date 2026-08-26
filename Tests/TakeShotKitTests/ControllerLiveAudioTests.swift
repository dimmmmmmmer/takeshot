import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// **The sound's lifecycle, from the controller's side — and the one property
/// the whole tap exists for: it is not the cart's speakers.**
///
/// Every test here runs on a controller with the monitor OFF. That is not a
/// convenience, it is the condition: `ControllerHarness` switches
/// `monitorEnabled` off for every controller it builds — deliberately, so a
/// suite never plays tones out of the machine running it — so a feed that
/// depended on the speakers would deliver nothing at all in this file, and the
/// design that was replaced would have.
@Suite(.enabled(if: SRTVideoEncoder.isSupported && AACConverter.isSupported,
                "no H.264 or AAC encoder on this machine"))
@MainActor
struct ControllerLiveAudioTests {
    /// Nothing listening: no encoder, and — the part that costs the capture
    /// queue — no tap on the pipeline either.
    @Test func theSwitchOffMeansNoEncoderAndNoTap() async throws {
        try await SRTProbe.run(live: true) { controller, _ in
            #expect(controller.settings.srt.enabled == nil)
            #expect(controller.mirrors.liveAudioEncoder == nil)
            #expect(!controller.pipeline.hasAudioTaps,
                    "the capture queue is mixing for nobody")
            try await Task.sleep(for: .milliseconds(200))
            #expect(!controller.pipeline.hasAudioTaps)
        }
    }

    /// The switch builds both, and they are built TOGETHER — a tap over a dead
    /// encoder is a state `CaptureController+LiveAudio` exists to make
    /// unreachable.
    @Test func theSwitchBuildsTheEncoderAndRegistersTheTap() async throws {
        try await SRTProbe.run(configure: SRTProbe.caller) { controller, _ in
            controller.settings.srt.enabled = true
            #expect(controller.mirrors.liveAudioEncoder != nil)
            #expect(controller.pipeline.hasAudioTaps)
            // …with the speakers still off, which is where the harness left them
            #expect(!controller.monitorOn)
            #expect(controller.settings.audio.monitorEnabled != true)
        }
    }

    /// …and switching it off takes both away again.
    @Test func theSwitchOffDropsTheEncoderAndTheTap() async throws {
        try await SRTProbe.run(configure: SRTProbe.caller) { controller, _ in
            controller.settings.srt.enabled = true
            #expect(controller.pipeline.hasAudioTaps)

            controller.settings.srt.enabled = nil
            #expect(controller.mirrors.liveAudioEncoder == nil)
            #expect(!controller.pipeline.hasAudioTaps,
                    "the tap outlived the transport that asked for it")
        }
    }

    /// A settings edit rebuilds the link on a debounce, and the tap must not be
    /// left behind by the teardown half of it.
    ///
    /// The hazard is specific: `stopSRTOutput` drops the encoder when nothing
    /// wants sound, and the restart builds another. A tap registered against
    /// the OLD encoder and never removed would keep a stopped converter alive
    /// on the capture queue for the rest of the session.
    @Test func aRebuildLeavesExactlyOneTapBehind() async throws {
        try await SRTProbe.run(configure: SRTProbe.caller) { controller, log in
            controller.settings.srt.enabled = true
            let first = try #require(controller.mirrors.liveAudioEncoder)
            controller.settings.srt.address = "10.0.9.9"
            #expect(await ControllerWait.until { log.all.count == 2 },
                    "the link was not rebuilt")
            #expect(controller.pipeline.hasAudioTaps)
            // The same encoder, kept: the restart never let `wanted` go false,
            // so nothing was torn down and rebuilt for an address change.
            #expect(controller.mirrors.liveAudioEncoder === first)

            controller.settings.srt.enabled = nil
            #expect(!controller.pipeline.hasAudioTaps)
        }
    }

    /// **The whole chain, with the speakers off**: board audio → the tap → AAC
    /// → a second PID → the socket.
    ///
    /// This is the test the feature is for. `monitorEnabled` is false
    /// throughout, and sound reaches the link anyway.
    @Test func theSoundReachesTheLinkWithTheSpeakersOff() async throws {
        try await SRTProbe.run(live: true,
                               configure: SRTProbe.caller) { controller, log in
            controller.settings.srt.enabled = true
            #expect(!controller.monitorOn)
            #expect(await ControllerWait.until { log.latest != nil })
            let stream: FakeSRTStream = try #require(log.latest)

            #expect(await ControllerWait.untilWritten {
                Self.carries(stream.datagrams, pid: MPEGTSMuxer.audioPID)
            }, "no sound ever reached the link with the speakers off")

            // …and the picture is still going, on its own PID. A feed that
            // gained sound by losing the picture is not the feature.
            #expect(Self.carries(stream.datagrams, pid: MPEGTSMuxer.videoPID))
            // Every datagram is still exactly what the socket was configured
            // for: the carry buffer emits whole ones or none.
            #expect(stream.datagrams.allSatisfy {
                $0.count == MPEGTSMuxer.datagramLength
            }, "a datagram was not 1316 bytes")
            // …and none of it happened on the capture queue.
            #expect(stream.queues.allSatisfy { $0 == SRTMirror.queueLabel },
                    "the send ran on \(Set(stream.queues))")
        }
    }

    /// **A receiver is told about the second stream.** Sound on a PID the
    /// program map does not declare is sound every demuxer discards.
    ///
    /// That the map is turned on by an access unit ARRIVING rather than by an
    /// encoder existing is pinned where it is deterministic —
    /// `SRTAudioMirrorTests` — because the order the two happen in here is a
    /// race the app wins either way: on this machine the tap is delivering
    /// packets before VideoToolbox has produced its first keyframe, so the
    /// first map on the wire already declares both.
    @Test func theMapOnTheWireDeclaresBothStreams() async throws {
        try await SRTProbe.run(live: true,
                               configure: SRTProbe.caller) { controller, log in
            controller.settings.srt.enabled = true
            #expect(await ControllerWait.until { log.latest != nil })
            let stream: FakeSRTStream = try #require(log.latest)
            #expect(await ControllerWait.untilWritten {
                Self.carries(stream.datagrams, pid: MPEGTSMuxer.audioPID)
            }, "no sound reached the link")

            #expect(await ControllerWait.untilWritten {
                Self.mapLengths(stream.datagrams).contains(0x17)
            }, "the map never declared the sound it is carrying")
            // …and once it has, it does not go back: the flip is one way for
            // the life of the link.
            let lengths: [UInt8] = Self.mapLengths(stream.datagrams)
            let after = lengths.drop { $0 != 0x17 }
            #expect(after.allSatisfy { $0 == 0x17 },
                    "the map stopped declaring sound again: \(lengths)")
        }
    }

    /// Whether any packet in a run of datagrams is on `pid`.
    private static func carries(_ datagrams: [Data], pid: UInt16) -> Bool {
        MPEGTSFixtures.packets(datagrams)
            .contains { MPEGTSFixtures.pid(of: $0) == pid }
    }

    /// The `section_length` byte of every program map on the wire, in order.
    /// 0x12 is one stream and 0x17 is two.
    private static func mapLengths(_ datagrams: [Data]) -> [UInt8] {
        MPEGTSFixtures.packets(datagrams)
            .filter { MPEGTSFixtures.pid(of: $0) == MPEGTSMuxer.pmtPID }
            .compactMap { packet -> UInt8? in
                let payload: [UInt8] = MPEGTSFixtures.payload(of: packet)
                guard payload.count > 3, payload[1] == 0x02 else { return nil }
                return payload[3]
            }
    }
}
