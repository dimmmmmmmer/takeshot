import Foundation
import Testing

@testable import TakeShotKit

/// Fixtures and a reader for RTP, so the suites below can talk about packets
/// rather than about offsets.
///
/// The reassembler is HERE and not in `Sources` on purpose, exactly as
/// `MPEGTSFixtures` keeps the transport-stream reader in the test: the app only
/// ever sends, so a depacketizer in the shipping code would be untested
/// production code with no caller. What it is for is the one claim that matters
/// most about a packetizer — that what comes out the far end is what went in —
/// and the only honest way to make that claim is to undo the packetizing with
/// code written from the RFC rather than from the packetizer.
enum RTPFixtures {
    /// An access unit of `nals`, each given a four-byte start code — the Annex B
    /// shape `MPEGTSMuxer.accessUnit(from:)` produces.
    static func unit(nals: [[UInt8]], pts: Int64 = 0,
                     keyframe: Bool = false) -> MPEGTSMuxer.AccessUnit {
        var payload: [UInt8] = []
        for nal in nals { payload += MPEGTSMuxer.startCode + nal }
        return MPEGTSMuxer.AccessUnit(payload: payload, pts: pts,
                                      isKeyframe: keyframe)
    }

    /// A NAL unit of `bytes` total, whose first byte is a real header for
    /// `type`. Deterministic filler rather than a picture: nothing in the
    /// packetizer looks inside a NAL unit, and a fixture that pretended to be
    /// H.264 would only make the failures harder to read.
    static func nal(type: UInt8, bytes: Int) -> [UInt8] {
        // nal_ref_idc 3 in the top bits, so the FU indicator has something
        // other than zero to carry across.
        [0x60 | (type & 0x1F)] + (1..<bytes).map { UInt8($0 % 251) }
    }

    struct Packet {
        var version: UInt8
        var marker: Bool
        var payloadType: UInt8
        var sequence: UInt16
        var timestamp: UInt32
        var ssrc: UInt32
        var payload: [UInt8]
    }

    static func parse(_ data: Data) -> Packet {
        let bytes: [UInt8] = [UInt8](data)
        return Packet(
            version: bytes[0] >> 6,
            marker: bytes[1] & 0x80 != 0,
            payloadType: bytes[1] & 0x7F,
            sequence: UInt16(bytes[2]) << 8 | UInt16(bytes[3]),
            timestamp: UInt32(bytes[4]) << 24 | UInt32(bytes[5]) << 16
                | UInt32(bytes[6]) << 8 | UInt32(bytes[7]),
            ssrc: UInt32(bytes[8]) << 24 | UInt32(bytes[9]) << 16
                | UInt32(bytes[10]) << 8 | UInt32(bytes[11]),
            payload: Array(bytes[RTPH264Packetizer.headerLength...]))
    }

    /// The NAL units a receiver would rebuild, in order.
    ///
    /// RFC 6184 from the receiving side: a payload whose type is 1-23 IS a NAL
    /// unit; type 28 is a fragment, and the original header byte is put back
    /// together out of the FU indicator's top three bits and the FU header's
    /// bottom five.
    static func reassemble(_ packets: [Data]) -> [[UInt8]] {
        var out: [[UInt8]] = []
        var open: [UInt8] = []
        for packet in packets {
            let payload: [UInt8] = parse(packet).payload
            guard let first = payload.first else { continue }
            let type = first & 0x1F
            guard type == RTPH264Packetizer.fragmentationUnitA else {
                out.append(payload)
                continue
            }
            guard payload.count >= 2 else { continue }
            let fuHeader = payload[1]
            if fuHeader & 0x80 != 0 {
                open = [(first & 0xE0) | (fuHeader & 0x1F)]
            }
            open += payload.dropFirst(2)
            if fuHeader & 0x40 != 0 {
                out.append(open)
                open = []
            }
        }
        return out
    }

    static func packetizer(maximumPayload: Int
                           = RTPH264Packetizer.maximumPayload,
                           firstSequenceNumber: UInt16 = 0)
        -> RTPH264Packetizer {
        RTPH264Packetizer(ssrc: 0x1234_5678, payloadType: 102,
                          maximumPayload: maximumPayload,
                          firstSequenceNumber: firstSequenceNumber)
    }
}

/// What comes out of the packetizer is what went in.
///
/// The one claim the whole WebRTC path rests on and the only one a headless
/// suite can make about it: everything downstream — ICE, DTLS, the browser's
/// decoder — is somebody else's code on somebody else's machine, and every
/// mistake there looks the same from here. A packetizer that fragments wrongly
/// looks the same too, which is exactly why it is checked as arithmetic.
@Suite struct RTPReassemblyTests {
    /// An access unit far past the MTU comes back byte for byte.
    @Test func anAccessUnitLargerThanTheMTUComesBackByteIdentical() {
        let slice: [UInt8] = RTPFixtures.nal(type: 5, bytes: 5000)
        let sps: [UInt8] = RTPFixtures.nal(type: 7, bytes: 24)
        let pps: [UInt8] = RTPFixtures.nal(type: 8, bytes: 6)
        var packetizer = RTPFixtures.packetizer()
        let packets: [Data] = packetizer.packets(
            for: RTPFixtures.unit(nals: [sps, pps, slice], keyframe: true))
        #expect(packets.count > 4, "a 5 kB slice fitted \(packets.count) packets")
        #expect(RTPFixtures.reassemble(packets) == [sps, pps, slice])
    }

    /// And so does one that fits, which is the other half of the same claim:
    /// a small NAL unit must not be wrapped in anything at all.
    @Test func aSmallAccessUnitIsOnePacketPerNALUnitAndUnwrapped() {
        let units: [[UInt8]] = [
            MPEGTSMuxer.accessUnitDelimiter.suffix(2).map { $0 },
            RTPFixtures.nal(type: 1, bytes: 300),
        ]
        var packetizer = RTPFixtures.packetizer()
        let packets: [Data] = packetizer.packets(
            for: RTPFixtures.unit(nals: units))
        #expect(packets.count == 2)
        #expect(RTPFixtures.reassemble(packets) == units)
        // Unwrapped: the payload IS the NAL unit, header byte included.
        #expect(RTPFixtures.parse(packets[1]).payload == units[1])
    }

    /// Both start-code lengths are found. Three bytes never arrives from this
    /// app's own muxer — it writes four throughout and says why — but a NAL
    /// unit's own bytes cannot contain a start code, so accepting both cannot
    /// mis-split and does cover a future encoder that emits the short one.
    @Test func nalUnitsAreFoundBehindEitherStartCodeLength() {
        let first: [UInt8] = RTPFixtures.nal(type: 7, bytes: 12)
        let second: [UInt8] = RTPFixtures.nal(type: 8, bytes: 5)
        let annexB: [UInt8] = [0x00, 0x00, 0x00, 0x01] + first
            + [0x00, 0x00, 0x01] + second
        #expect(RTPH264Packetizer.nalUnits(in: annexB).map(Array.init)
            == [first, second])
    }

    /// Bytes that are not an access unit produce no packets rather than a
    /// packet of nothing. An empty RTP payload is a packet a receiver has to
    /// decide what to do with, and there is nothing to decide.
    @Test func bytesWithNoStartCodeInThemProduceNothing() {
        var packetizer = RTPFixtures.packetizer()
        let unit = MPEGTSMuxer.AccessUnit(payload: [0x01, 0x02, 0x03],
                                          pts: 0, isKeyframe: false)
        #expect(packetizer.packets(for: unit).isEmpty)
    }
}

/// The fragmentation rules, at the boundary where they are decided.
@Suite struct RTPFragmentationTests {
    /// A NAL unit exactly at the ceiling is ONE packet; one byte more is two.
    ///
    /// The off-by-one that matters: a `>=` here would fragment everything that
    /// exactly fits, and a `>` on the wrong side would emit a packet one byte
    /// past the MTU — which is not an error anywhere in this process, it is a
    /// datagram the network fragments and one lost fragment takes a frame with
    /// it.
    @Test func aNALUnitExactlyAtTheCeilingIsNotFragmented() {
        let ceiling = 400
        var packetizer = RTPFixtures.packetizer(maximumPayload: ceiling)
        let exact: [UInt8] = RTPFixtures.nal(type: 1, bytes: ceiling)
        #expect(packetizer.packets(for: RTPFixtures.unit(nals: [exact])).count
            == 1)
        let over: [UInt8] = RTPFixtures.nal(type: 1, bytes: ceiling + 1)
        let packets: [Data] = packetizer.packets(
            for: RTPFixtures.unit(nals: [over]))
        #expect(packets.count == 2, "one byte over made \(packets.count) packets")
        #expect(RTPFixtures.reassemble(packets) == [over])
    }

    /// The start bit is on the first fragment only and the end bit on the last
    /// only. A receiver reads the pair as "a picture starts/ends here", so a
    /// start bit on a middle fragment throws away everything before it.
    @Test func theFragmentStartAndEndBitsAreOnTheEndsAndNowhereElse() {
        var packetizer = RTPFixtures.packetizer(maximumPayload: 100)
        let packets: [Data] = packetizer.packets(
            for: RTPFixtures.unit(nals: [RTPFixtures.nal(type: 5, bytes: 1000)]))
        try? #require(packets.count >= 3)
        let headers: [UInt8] = packets.map { RTPFixtures.parse($0).payload[1] }
        #expect(headers.map { $0 & 0x80 != 0 }
            == [true] + [Bool](repeating: false, count: headers.count - 1))
        #expect(headers.map { $0 & 0x40 != 0 }
            == [Bool](repeating: false, count: headers.count - 1) + [true])
        // The reserved bit is zero on every one of them, and the type is the
        // fragmented unit's — not the FU-A type the indicator carries.
        #expect(headers.allSatisfy { $0 & 0x20 == 0 })
        #expect(headers.allSatisfy { $0 & 0x1F == 5 })
    }

    /// Every packet fits, fragmented or not — which is the whole reason the
    /// ceiling exists.
    @Test func noPacketEverExceedsTheMTU() {
        var packetizer = RTPFixtures.packetizer()
        let packets: [Data] = packetizer.packets(for: RTPFixtures.unit(nals: [
            RTPFixtures.nal(type: 7, bytes: 30),
            RTPFixtures.nal(type: 5, bytes: 60_000),
        ], keyframe: true))
        let ceiling = RTPH264Packetizer.headerLength
            + RTPH264Packetizer.maximumPayload
        #expect(packets.allSatisfy { $0.count <= ceiling },
                "largest packet \(packets.map(\.count).max() ?? 0) > \(ceiling)")
    }

    /// The ceiling is derived from the smallest MTU this path can meet, and the
    /// arithmetic is stated rather than trusted: 1280 (IPv6's guaranteed
    /// minimum, and libdatachannel's own default) less the RTP header, the SRTP
    /// tag, and the UDP and IPv6 headers.
    @Test func theCeilingLeavesRoomForEveryHeaderUnderIt() {
        let overhead = RTPH264Packetizer.headerLength + 10 + 8 + 40
        #expect(RTPH264Packetizer.maximumPayload + overhead <= 1280)
        // One encoder cannot feed both wire formats if they disagree on it.
        #expect(RTPH264Packetizer.clockHz == MPEGTSMuxer.clockHz)
    }
}

/// The three numbers in the header, which are the only state this type has.
@Suite struct RTPHeaderTests {
    /// One access unit, one timestamp — on every packet of it, fragment or not.
    /// A fragment stamped later than its own picture is a frame a receiver
    /// splits in two.
    @Test func everyPacketOfOneAccessUnitCarriesTheSameTimestamp() {
        var packetizer = RTPFixtures.packetizer(maximumPayload: 100)
        let packets: [Data] = packetizer.packets(for: RTPFixtures.unit(
            nals: [RTPFixtures.nal(type: 5, bytes: 900)], pts: 90_000))
        #expect(Set(packets.map { RTPFixtures.parse($0).timestamp }) == [90_000])
    }

    /// The 90 kHz stamp is truncated to 32 bits rather than clamped, which is
    /// what RTP does: the field wraps, and a receiver follows it. A clamp would
    /// freeze the picture's clock after thirteen and a half hours.
    @Test func theTimestampWrapsWithTheField() {
        var packetizer = RTPFixtures.packetizer()
        let past = Int64(UInt32.max) + 5
        let packets: [Data] = packetizer.packets(for: RTPFixtures.unit(
            nals: [RTPFixtures.nal(type: 1, bytes: 40)], pts: past))
        #expect(RTPFixtures.parse(packets[0]).timestamp == 4)
    }

    /// The marker bit says "the picture is complete" and is on the last packet
    /// of the access unit and nowhere else — including across a fragmented NAL
    /// unit that is not the last one.
    @Test func theMarkerBitIsOnTheLastPacketAndOnlyThere() {
        var packetizer = RTPFixtures.packetizer(maximumPayload: 100)
        let packets: [Data] = packetizer.packets(for: RTPFixtures.unit(nals: [
            RTPFixtures.nal(type: 5, bytes: 400),
            RTPFixtures.nal(type: 1, bytes: 40),
        ]))
        let markers: [Bool] = packets.map { RTPFixtures.parse($0).marker }
        #expect(markers == [Bool](repeating: false, count: markers.count - 1)
            + [true])
    }

    /// The sequence number increments by one per PACKET — not per access unit —
    /// and wraps at 16 bits. A receiver reads a gap in it as a lost packet, so
    /// a counter that skipped on a fragment boundary would report loss on a
    /// perfect link.
    @Test func theSequenceNumberIncrementsPerPacketAndWraps() {
        var packetizer = RTPFixtures.packetizer(maximumPayload: 100,
                                                firstSequenceNumber: 65_534)
        var packets: [Data] = packetizer.packets(for: RTPFixtures.unit(
            nals: [RTPFixtures.nal(type: 5, bytes: 400)]))
        packets += packetizer.packets(for: RTPFixtures.unit(
            nals: [RTPFixtures.nal(type: 1, bytes: 40)], pts: 3600))
        let numbers: [UInt16] = packets.map { RTPFixtures.parse($0).sequence }
        #expect(numbers.first == 65_534)
        #expect(numbers == (0..<numbers.count).map {
            UInt16(truncatingIfNeeded: 65_534 + $0)
        }, "\(numbers)")
        #expect(numbers.contains(0), "the counter did not wrap")
    }

    /// The identity the answer promised the browser: version 2, the offer's own
    /// payload type, and the SSRC the answer's `a=ssrc` line named. A payload
    /// type of ours rather than the offer's is a stream the browser has no
    /// decoder mapped to.
    @Test func theHeaderCarriesTheNegotiatedIdentity() {
        var packetizer = RTPH264Packetizer(ssrc: 0xDEAD_BEEF, payloadType: 96)
        let packets: [Data] = packetizer.packets(for: RTPFixtures.unit(
            nals: [RTPFixtures.nal(type: 1, bytes: 40)]))
        let packet = RTPFixtures.parse(packets[0])
        #expect(packet.version == 2)
        #expect(packet.payloadType == 96)
        #expect(packet.ssrc == 0xDEAD_BEEF)
    }
}
