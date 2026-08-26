import CaptureCore
import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import TakeShotKit

/// The mirror with both encoders on it: two elementary streams onto one socket,
/// and the program map that follows the BYTES rather than the wiring.
///
/// Driven at the mirror rather than through a controller because the order the
/// two streams start in is a race up there — on a fast machine the tap is
/// delivering packets before VideoToolbox has produced its first keyframe — and
/// the claim being made here is exactly about that order.
@Suite(.enabled(if: SRTVideoEncoder.isSupported && AACConverter.isSupported,
                "no H.264 or AAC encoder on this machine"))
struct SRTAudioMirrorTests {
    /// A mirror with a real AAC encoder in front of it, over a fake link.
    private struct Rig {
        let video: LiveVideoEncoder
        let audio: LiveAudioEncoder
        let mirror: SRTMirror
        let stream: FakeSRTStream

        func stop() {
            mirror.stop()
            video.stop()
            audio.stop()
        }
    }

    private static func rig() -> Rig {
        let stream = FakeSRTStream()
        let clock = LiveClock()
        let video = LiveVideoEncoder(bitsPerSecond: 4_000_000, clock: clock)
        let audio = LiveAudioEncoder(clock: clock)
        let log = SRTEventLog()
        let mirror = SRTMirror(endpoint: SRTFixtures.endpoint, encoder: video,
                               audioEncoder: audio, factory: { _ in stream },
                               onEvent: { log.record($0) })
        mirror.start()
        let deadline = Date().addingTimeInterval(5)
        while !video.hasSinks, log.all.isEmpty, Date() < deadline {
            usleep(2_000)
        }
        return Rig(video: video, audio: audio, mirror: mirror, stream: stream)
    }

    /// The `section_length` byte of every program map on the wire, in order.
    private static func mapLengths(_ datagrams: [Data]) -> [UInt8] {
        MPEGTSFixtures.packets(datagrams)
            .filter { MPEGTSFixtures.pid(of: $0) == MPEGTSMuxer.pmtPID }
            .compactMap { packet -> UInt8? in
                let payload: [UInt8] = MPEGTSFixtures.payload(of: packet)
                guard payload.count > 3, payload[1] == 0x02 else { return nil }
                return payload[3]
            }
    }

    private static func pushFrames(_ rig: Rig, count: Int) async throws {
        let buffer = try SRTFixtures.displayBuffer()
        for _ in 0..<count {
            rig.video.offer(buffer, framesPerSecond: 25)
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    /// **An encoder that has produced nothing does not get into the map.**
    ///
    /// The failure this rules out is the one `TakeWriter+Audio` pads a starved
    /// track to avoid, one transport along: a PMT naming a PID nothing feeds is
    /// a receiver waiting for sound that is not coming, which several of them
    /// answer by holding the picture too. Constructing an AAC encoder is not
    /// the same claim as this machine having produced an access unit.
    @Test func anAudioEncoderThatHasProducedNothingIsNotDeclared() async throws {
        let rig = Self.rig()
        defer { rig.stop() }
        try await Self.pushFrames(rig, count: 8)

        let lengths: [UInt8] = Self.mapLengths(rig.stream.datagrams)
        #expect(!lengths.isEmpty, "no program map reached the link at all")
        #expect(lengths.allSatisfy { $0 == 0x12 },
                "the map declared sound nothing had produced: \(lengths)")
        // Counted rather than collected: a failed `#expect` renders its
        // operands, and a list of 188-byte packets is pages of bytes.
        let audio: Int = MPEGTSFixtures.packets(rig.stream.datagrams)
            .filter { MPEGTSFixtures.pid(of: $0) == MPEGTSMuxer.audioPID }.count
        #expect(audio == 0, "\(audio) audio packets with no encode")
    }

    /// …and the first unit that DOES arrive turns it on, and pulls a keyframe
    /// with it so whoever is already watching gets the new map.
    @Test func theFirstAccessUnitTurnsTheMapOn() async throws {
        let rig = Self.rig()
        defer { rig.stop() }
        try await Self.pushFrames(rig, count: 6)
        #expect(Self.mapLengths(rig.stream.datagrams).allSatisfy { $0 == 0x12 })

        // Registered alongside the mirror: a second sink on one converter,
        // which is also what lets this test WAIT for a unit rather than for a
        // clock.
        let taken = AACCollector()
        rig.audio.addSink(taken) { taken.take($0) }
        await LiveAudioFixtures.drive(rig.audio, packets: 12, into: taken,
                                      expecting: 8)
        // Keyframes are what carry a map, so the wire needs frames after the
        // flip for the new one to appear on it.
        try await Self.pushFrames(rig, count: 10)

        let lengths: [UInt8] = Self.mapLengths(rig.stream.datagrams)
        #expect(lengths.contains(0x17),
                "the map never grew a second stream: \(lengths)")
        #expect(lengths.first == 0x12,
                "the map declared sound before any arrived: \(lengths)")
        let audio: Int = MPEGTSFixtures.packets(rig.stream.datagrams)
            .filter { MPEGTSFixtures.pid(of: $0) == MPEGTSMuxer.audioPID }.count
        #expect(audio > 0, "no sound reached the link")
    }

    /// Both streams share the socket, and everything on it is still a whole
    /// datagram of whole transport packets.
    @Test func bothStreamsShareOneSocketAndTheDatagramShape() async throws {
        let rig = Self.rig()
        defer { rig.stop() }
        let taken = AACCollector()
        rig.audio.addSink(taken) { taken.take($0) }
        await LiveAudioFixtures.drive(rig.audio, packets: 16, into: taken,
                                      expecting: 10)
        try await Self.pushFrames(rig, count: 10)

        let datagrams: [Data] = rig.stream.datagrams
        #expect(datagrams.allSatisfy { $0.count == MPEGTSMuxer.datagramLength },
                "a datagram was not 1316 bytes")
        let pids = Set(MPEGTSFixtures.packets(datagrams)
            .map { MPEGTSFixtures.pid(of: $0) })
        #expect(pids.contains(MPEGTSMuxer.videoPID))
        #expect(pids.contains(MPEGTSMuxer.audioPID))
        #expect(pids.contains(MPEGTSMuxer.pmtPID))
        // …and the send never left the mirror's own queue.
        #expect(Set(rig.stream.queues) == [SRTMirror.queueLabel],
                "the send ran on \(Set(rig.stream.queues))")
    }

    /// A mirror built with no audio encoder is exactly what it was before there
    /// was any sound: one stream, one PID, one map shape.
    ///
    /// The seam a stub build sits on — and the one an operator on a machine
    /// with no AAC codec gets, since the map follows the bytes.
    @Test func withNoAudioEncoderNothingAboutTheStreamChanges() async throws {
        let stream = FakeSRTStream()
        let video = LiveVideoEncoder(bitsPerSecond: 4_000_000)
        let log = SRTEventLog()
        let mirror = SRTMirror(endpoint: SRTFixtures.endpoint, encoder: video,
                               audioEncoder: nil, factory: { _ in stream },
                               onEvent: { log.record($0) })
        let rig = Rig(video: video, audio: LiveAudioEncoder(), mirror: mirror,
                      stream: stream)
        mirror.start()
        let deadline = Date().addingTimeInterval(5)
        while !video.hasSinks, log.all.isEmpty, Date() < deadline {
            usleep(2_000)
        }
        defer { rig.stop() }

        try await Self.pushFrames(rig, count: 10)
        let pids = Set(MPEGTSFixtures.packets(stream.datagrams)
            .map { MPEGTSFixtures.pid(of: $0) })
        #expect(!pids.contains(MPEGTSMuxer.audioPID))
        #expect(Self.mapLengths(stream.datagrams).allSatisfy { $0 == 0x12 })
    }
}
