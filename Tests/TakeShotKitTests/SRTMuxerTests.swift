import Foundation
import Testing

@testable import TakeShotKit

/// Fixtures and readers for the transport stream, so the suites below can talk
/// about packets rather than about offsets.
enum MPEGTSFixtures {
    /// An access unit of `bytes` synthetic payload. Not real H.264 — the muxer
    /// never looks inside a NAL unit, and a fixture that pretended to be a
    /// picture would only make the failures harder to read.
    static func unit(bytes: Int, pts: Int64 = 0,
                     keyframe: Bool = false) -> MPEGTSMuxer.AccessUnit {
        let payload: [UInt8] = (0..<bytes).map { UInt8($0 % 251) }
        return MPEGTSMuxer.AccessUnit(payload: payload, pts: pts,
                                      isKeyframe: keyframe)
    }

    /// The 188-byte packets inside a run of datagrams.
    static func packets(_ datagrams: [Data]) -> [[UInt8]] {
        var out: [[UInt8]] = []
        for datagram in datagrams {
            let bytes: [UInt8] = [UInt8](datagram)
            var offset = 0
            while offset + MPEGTSMuxer.packetLength <= bytes.count {
                out.append(Array(
                    bytes[offset..<(offset + MPEGTSMuxer.packetLength)]))
                offset += MPEGTSMuxer.packetLength
            }
        }
        return out
    }

    static func pid(of packet: [UInt8]) -> UInt16 {
        (UInt16(packet[1] & 0x1F) << 8) | UInt16(packet[2])
    }

    static func startsUnit(_ packet: [UInt8]) -> Bool {
        packet[1] & 0x40 != 0
    }

    static func continuity(of packet: [UInt8]) -> UInt8 {
        packet[3] & 0x0F
    }

    /// The payload bytes of one packet: past the header, and past the adaptation
    /// field when the control bits say there is one.
    static func payload(of packet: [UInt8]) -> [UInt8] {
        guard packet[3] & 0x20 != 0 else { return Array(packet[4...]) }
        let fieldLength = Int(packet[4])
        let start = 5 + fieldLength
        return start <= packet.count ? Array(packet[start...]) : []
    }

    /// Every payload byte carried on one PID, in order — the elementary stream
    /// as a receiver would reassemble it.
    static func stream(_ datagrams: [Data], pid wanted: UInt16) -> [UInt8] {
        packets(datagrams).filter { pid(of: $0) == wanted }
            .flatMap { payload(of: $0) }
    }

    /// The PTS of every access unit in a run of datagrams, in order.
    ///
    /// Reads the packets that START a unit, which is also what skips the tables:
    /// they carry no PES header and no timestamp.
    static func timestamps(_ datagrams: [Data]) -> [Int64] {
        packets(datagrams)
            .filter { pid(of: $0) == MPEGTSMuxer.videoPID && startsUnit($0) }
            .compactMap { packet -> Int64? in
                let bytes: [UInt8] = payload(of: packet)
                guard bytes.count >= 14 else { return nil }
                return timestamp(Array(bytes[9..<14]))
            }
    }

    /// A 33-bit timestamp read back out of the five bytes it was spread over.
    static func timestamp(_ bytes: [UInt8]) -> Int64 {
        var value = Int64(bytes[0] >> 1 & 0x07) << 30
        value |= Int64(bytes[1]) << 22
        value |= Int64(bytes[2] >> 1) << 15
        value |= Int64(bytes[3]) << 7
        value |= Int64(bytes[4] >> 1)
        return value
    }
}

/// The transport stream, checked as bytes.
///
/// A wire format cannot be verified by looking at a picture — a receiver that
/// shows something is evidence that nothing is badly wrong and no evidence at all
/// about the parts a strict demuxer, a hardware decoder or a cloud gateway will
/// reject. So everything here is arithmetic, and the number the whole design rests
/// on (1316 = 188 × 7) is the first thing checked rather than the last.
@Suite struct SRTMuxerTests {
    // MARK: - the shape of the wire

    /// The one number the socket and the muxer both depend on.
    @Test func theDatagramIsSevenPacketsAndThatIsWhatSRTAsksFor() {
        #expect(MPEGTSMuxer.packetLength == 188)
        #expect(MPEGTSMuxer.packetsPerDatagram == 7)
        // libsrt's SRT_LIVE_DEF_PLSIZE, which the bridge sets SRTO_PAYLOADSIZE to.
        #expect(MPEGTSMuxer.datagramLength == 1316)
        #expect(MPEGTSMuxer.payloadPerPacket == 184)
    }

    /// Every datagram is exactly the payload size, padded when it has to be.
    /// A short message would be legal SRT and a coin toss at the far end.
    @Test func everyDatagramIsExactlyTheConfiguredPayloadSize() {
        var muxer = MPEGTSMuxer()
        let sizes: [Int] = [1, 100, 184, 1000, 40_000, 120_000]
        for bytes in sizes {
            let datagrams: [Data] = muxer.datagrams(
                for: MPEGTSFixtures.unit(bytes: bytes, keyframe: true))
            #expect(!datagrams.isEmpty, "no datagram for a \(bytes)-byte unit")
            #expect(datagrams.allSatisfy {
                $0.count == MPEGTSMuxer.datagramLength
            }, "a datagram is not 1316 bytes for \(bytes) bytes of payload")
        }
    }

    /// Two things every receiver checks before it looks at a payload, and neither
    /// is derived from a constant this suite also wrote.
    ///
    /// `transport_scrambling_control` has to be zero: a stream that claims to be
    /// scrambled is refused outright, and those two bits share a byte with the
    /// adaptation-field control this muxer does set — so a shift by two would be
    /// invisible to every other test here and fatal at the far end. And a PID has
    /// to be one a receiver will follow: 0x0000 is the PAT by definition,
    /// 0x0001-0x000F are reserved and 0x1FFF is the null packet, so a video or map
    /// PID in any of those is a stream nobody can demux.
    @Test func noPacketClaimsToBeScrambledAndEveryPIDIsALegalOne() {
        var muxer = MPEGTSMuxer()
        let datagrams: [Data] = muxer.datagrams(
            for: MPEGTSFixtures.unit(bytes: 5000, keyframe: true))
        for packet in MPEGTSFixtures.packets(datagrams) {
            #expect(packet[3] & 0xC0 == 0, "a packet claims to be scrambled")
            #expect(packet[1] & 0x80 == 0, "a packet sets the error indicator")
        }
        let carried: [UInt16] = [MPEGTSMuxer.pmtPID, MPEGTSMuxer.videoPID]
        for pid in carried {
            #expect(pid > 0x000F, "PID \(pid) is in the reserved range")
            #expect(pid < MPEGTSMuxer.nullPID, "PID \(pid) is the null PID")
        }
        #expect(MPEGTSMuxer.patPID == 0x0000)
        #expect(MPEGTSMuxer.nullPID == 0x1FFF)
    }

    @Test func everyPacketStartsWithTheSyncByte() {
        var muxer = MPEGTSMuxer()
        let datagrams: [Data] = muxer.datagrams(
            for: MPEGTSFixtures.unit(bytes: 5000, keyframe: true))
        let packets: [[UInt8]] = MPEGTSFixtures.packets(datagrams)
        #expect(packets.count == datagrams.count * 7)
        #expect(packets.allSatisfy { $0[0] == 0x47 },
                "a packet does not begin with 0x47")
    }

    /// The padding is null packets and not zeroes: a receiver has to be able to
    /// discard it by PID rather than choke on a packet that is not one.
    @Test func theTailIsPaddedWithNullPackets() {
        var muxer = MPEGTSMuxer()
        // 200 bytes of payload is two video packets plus the two tables, so four
        // of the seven slots are used and three are padding.
        let datagrams: [Data] = muxer.datagrams(
            for: MPEGTSFixtures.unit(bytes: 200, keyframe: true))
        let packets: [[UInt8]] = MPEGTSFixtures.packets(datagrams)
        let nulls: Int = packets.filter {
            MPEGTSFixtures.pid(of: $0) == MPEGTSMuxer.nullPID
        }.count
        #expect(nulls == 3, "\(nulls) null packets in a four-packet frame")
        #expect(packets.count - nulls == 4)
    }

    // MARK: - what the tables say

    /// The tables ride with the keyframe, and only with the keyframe. Sending
    /// them every frame would cost 2 packets in 7 at low bitrates; sending them
    /// on a timer of their own would let a receiver hold tables it cannot use.
    @Test func theTablesRideWithTheKeyframeAndNotWithTheRest() {
        var muxer = MPEGTSMuxer()
        let key: [Data] = muxer.datagrams(
            for: MPEGTSFixtures.unit(bytes: 900, keyframe: true))
        let inter: [Data] = muxer.datagrams(
            for: MPEGTSFixtures.unit(bytes: 900, pts: 3600, keyframe: false))
        let keyPIDs: [UInt16] = MPEGTSFixtures.packets(key)
            .map(MPEGTSFixtures.pid)
        let interPIDs: [UInt16] = MPEGTSFixtures.packets(inter)
            .map(MPEGTSFixtures.pid)
        #expect(keyPIDs.contains(MPEGTSMuxer.patPID))
        #expect(keyPIDs.contains(MPEGTSMuxer.pmtPID))
        #expect(!interPIDs.contains(MPEGTSMuxer.patPID))
        #expect(!interPIDs.contains(MPEGTSMuxer.pmtPID))
        // …and the tables come FIRST, so a receiver reading the datagram in order
        // knows what the video PID is before it meets it.
        #expect(keyPIDs.first == MPEGTSMuxer.patPID)
        #expect(keyPIDs.dropFirst().first == MPEGTSMuxer.pmtPID)
    }

    /// The program map names one H.264 stream on the video PID, and says that
    /// stream is its own clock reference.
    @Test func theProgramMapDeclaresH264OnTheVideoPID() {
        var muxer = MPEGTSMuxer()
        let datagrams: [Data] = muxer.datagrams(
            for: MPEGTSFixtures.unit(bytes: 100, keyframe: true))
        let map: [UInt8] = MPEGTSFixtures.stream(datagrams, pid: MPEGTSMuxer.pmtPID)
        // pointer field, then the section: table_id 0x02, then the length pair.
        #expect(map[0] == 0x00)
        #expect(map[1] == 0x02)
        #expect(map[2] == 0xB0)
        #expect(map[3] == 0x12, "the PMT section length is not 18 bytes")
        // PCR_PID and elementary_PID are both the video PID.
        let pcrPID: UInt16 = (UInt16(map[9] & 0x1F) << 8) | UInt16(map[10])
        #expect(pcrPID == MPEGTSMuxer.videoPID)
        #expect(map[13] == MPEGTSMuxer.streamTypeH264)
        let elementary: UInt16 = (UInt16(map[14] & 0x1F) << 8) | UInt16(map[15])
        #expect(elementary == MPEGTSMuxer.videoPID)
    }

    /// The PAT points at the PMT's PID and declares one program.
    @Test func theProgramAssociationPointsAtTheMap() {
        var muxer = MPEGTSMuxer()
        let datagrams: [Data] = muxer.datagrams(
            for: MPEGTSFixtures.unit(bytes: 100, keyframe: true))
        let table: [UInt8] = MPEGTSFixtures.stream(datagrams,
                                                   pid: MPEGTSMuxer.patPID)
        #expect(table[1] == 0x00)
        #expect(table[3] == 0x0D, "the PAT section length is not 13 bytes")
        let program: UInt16 = (UInt16(table[9]) << 8) | UInt16(table[10])
        #expect(program == MPEGTSMuxer.programNumber)
        let mapPID: UInt16 = (UInt16(table[11] & 0x1F) << 8) | UInt16(table[12])
        #expect(mapPID == MPEGTSMuxer.pmtPID)
    }

    /// **The CRC is pinned against the algorithm, not against this code.**
    ///
    /// 0x0376E6E7 is the published check value for CRC-32/MPEG-2 over the ASCII
    /// digits "123456789". Comparing a table's CRC to `crc32` of its own bytes
    /// would pass with any polynomial at all — including a wrong one that every
    /// receiver on set would reject.
    @Test func theTableChecksumIsTheOneTheStandardNames() {
        let digits: [UInt8] = Array("123456789".utf8)
        #expect(MPEGTSMuxer.crc32(digits) == 0x0376_E6E7)
        // Zero-length input is the initial register, unmodified and un-xored,
        // which is what makes this the MPEG-2 variant rather than the common one.
        #expect(MPEGTSMuxer.crc32([]) == 0xFFFF_FFFF)
    }

    /// …and each table's own CRC really is over its own section.
    @Test func eachTableCarriesTheChecksumOfItsSection() {
        var muxer = MPEGTSMuxer()
        let datagrams: [Data] = muxer.datagrams(
            for: MPEGTSFixtures.unit(bytes: 100, keyframe: true))
        let tables: [(UInt16, Int)] = [(MPEGTSMuxer.patPID, 13),
                                       (MPEGTSMuxer.pmtPID, 18)]
        for (pid, length) in tables {
            let payload: [UInt8] = MPEGTSFixtures.stream(datagrams, pid: pid)
            let body: [UInt8] = Array(payload[1..<length])
            let stated: UInt32 = (UInt32(payload[length]) << 24)
                | (UInt32(payload[length + 1]) << 16)
                | (UInt32(payload[length + 2]) << 8) | UInt32(payload[length + 3])
            #expect(MPEGTSMuxer.crc32(body) == stated,
                    "the checksum on PID \(pid) is not over its own section")
        }
    }

    // MARK: - what the packets carry

    /// The elementary stream comes out byte for byte, in order, once the headers
    /// are stripped. This is the claim a receiver actually depends on.
    @Test func thePayloadSurvivesPacketisationExactly() {
        var muxer = MPEGTSMuxer()
        let unit: MPEGTSMuxer.AccessUnit =
            MPEGTSFixtures.unit(bytes: 5000, pts: 90_000, keyframe: true)
        let datagrams: [Data] = muxer.datagrams(for: unit)
        let elementary: [UInt8] = MPEGTSFixtures.stream(datagrams,
                                                        pid: MPEGTSMuxer.videoPID)
        // PES header: start code, stream id, length, two flag bytes, header
        // length, and five bytes of PTS.
        #expect(Array(elementary[0..<4]) == [0x00, 0x00, 0x01, 0xE0])
        #expect(elementary[6] == 0x80)
        #expect(elementary[7] == 0x80, "the PES says it carries a DTS")
        #expect(elementary[8] == 0x05)
        let carried: [UInt8] = Array(elementary[14..<(14 + unit.payload.count)])
        #expect(carried == unit.payload, "the payload did not survive intact")
    }

    /// A 33-bit timestamp read back out of its five bytes, over values that
    /// exercise every one of the interleaved marker bits.
    @Test func theTimestampRoundTripsThroughItsFiveBytes() {
        let stamps: [Int64] = [0, 1, 90_000, 3_600 * 90_000, 8_589_934_591]
        for ticks in stamps {
            let bytes: [UInt8] = MPEGTSMuxer.timestamp(ticks, marker: 0x2)
            #expect(MPEGTSFixtures.timestamp(bytes) == ticks,
                    "\(ticks) did not survive the PTS encoding")
            // The marker bits the standard sets to one, so no header byte can
            // ever look like the start of a packet.
            #expect(bytes[0] & 0xF0 == 0x20)
            #expect(bytes[0] & 0x01 == 1)
            #expect(bytes[2] & 0x01 == 1)
            #expect(bytes[4] & 0x01 == 1)
        }
    }

    /// The PES carries the access unit's own timestamp.
    @Test func thePESCarriesTheAccessUnitsTimestamp() {
        var muxer = MPEGTSMuxer()
        let datagrams: [Data] = muxer.datagrams(
            for: MPEGTSFixtures.unit(bytes: 400, pts: 1_234_567))
        let elementary: [UInt8] = MPEGTSFixtures.stream(datagrams,
                                                        pid: MPEGTSMuxer.videoPID)
        #expect(MPEGTSFixtures.timestamp(Array(elementary[9..<14])) == 1_234_567)
    }

    /// The first packet of an access unit carries the clock, and says so; a
    /// keyframe also says a receiver may start there.
    @Test func theFirstPacketCarriesTheClockAndFlagsARandomAccessPoint() throws {
        var muxer = MPEGTSMuxer()
        let flags: [Bool] = [true, false]
        for keyframe in flags {
            let datagrams: [Data] = muxer.datagrams(
                for: MPEGTSFixtures.unit(bytes: 3000, pts: 45_000,
                                         keyframe: keyframe))
            let video: [[UInt8]] = MPEGTSFixtures.packets(datagrams)
                .filter { MPEGTSFixtures.pid(of: $0) == MPEGTSMuxer.videoPID }
            let first: [UInt8] = try #require(video.first)
            #expect(MPEGTSFixtures.startsUnit(first))
            #expect(first[3] & 0x30 == 0x30, "no adaptation field on the first")
            #expect(first[4] == 0x07, "the adaptation field is not 7 bytes")
            #expect(first[5] & 0x10 != 0, "the PCR flag is not set")
            #expect((first[5] & 0x40 != 0) == keyframe,
                    "the random-access indicator does not follow the keyframe")
            // …and only the first: a second PCR per frame would be waste, and
            // 40 ms is already well inside the standard's 100.
            #expect(video.dropFirst().allSatisfy { !MPEGTSFixtures.startsUnit($0) })
        }
    }

    /// The PCR is the presentation time, exactly. A muxer that offset it would be
    /// adding latency the latency setting does not account for.
    @Test func theClockReferenceIsThePresentationTime() {
        let field: [UInt8] = MPEGTSMuxer.clockField(pcr: 2_700_000,
                                                    randomAccess: true)
        var base = Int64(field[2]) << 25
        base |= Int64(field[3]) << 17
        base |= Int64(field[4]) << 9
        base |= Int64(field[5]) << 1
        base |= Int64(field[6] >> 7)
        #expect(base == 2_700_000)
        // The 27 MHz extension is zero and the six reserved bits are set.
        #expect(field[6] & 0x7E == 0x7E)
        #expect(field[7] == 0x00)
    }

    /// Continuity counts up per PID and wraps at sixteen. A receiver reads a jump
    /// in it as a lost packet, so a muxer that reset it per frame would report a
    /// loss on every frame.
    @Test func continuityCountsPerPIDAndWraps() {
        var muxer = MPEGTSMuxer()
        var seen: [UInt8] = []
        for frame in 0..<20 {
            let datagrams: [Data] = muxer.datagrams(
                for: MPEGTSFixtures.unit(bytes: 100, pts: Int64(frame) * 3600))
            seen += MPEGTSFixtures.packets(datagrams)
                .filter { MPEGTSFixtures.pid(of: $0) == MPEGTSMuxer.videoPID }
                .map(MPEGTSFixtures.continuity)
        }
        #expect(seen.count == 20, "a 100-byte unit took more than one packet")
        for (index, counter) in seen.enumerated() {
            #expect(counter == UInt8(index % 16),
                    "packet \(index) has continuity \(counter)")
        }
    }

    // MARK: - the stuffing, which is where a byte goes missing

    /// The two shapes of an adaptation field used purely as padding. One spare
    /// byte cannot hold a flags byte, so the format spends it on a length of
    /// zero instead — and that special case is where an off-by-one lives.
    @Test func stuffingTakesExactlyTheBytesItIsAskedFor() {
        #expect(MPEGTSMuxer.stuffing(bytes: 0, after: []) == [UInt8]())
        #expect(MPEGTSMuxer.stuffing(bytes: 1, after: []) == [UInt8]([0x00]))
        #expect(MPEGTSMuxer.stuffing(bytes: 2, after: [])
            == [UInt8]([0x01, 0x00]))
        #expect(MPEGTSMuxer.stuffing(bytes: 5, after: [])
            == [UInt8]([0x04, 0x00, 0xFF, 0xFF, 0xFF]))
        for bytes: Int in 0...183 {
            #expect(MPEGTSMuxer.stuffing(bytes: bytes, after: []).count == bytes,
                    "\(bytes) bytes of stuffing came out a different size")
        }
    }

    /// A payload that lands exactly on a packet boundary needs no stuffing at
    /// all, and one byte over needs the awkward shape. Both are 188 bytes.
    @Test func aPayloadOnEitherSideOfABoundaryStillFillsWholePackets() {
        // 176 is what the first packet has room for once the clock field is on;
        // the PES header is 14 bytes, so these three land on, one under and one
        // over the second packet's 184.
        let sizes: [Int] = [176 - 14, 176 - 14 + 183, 176 - 14 + 184,
                            176 - 14 + 185]
        for bytes in sizes {
            var muxer = MPEGTSMuxer()
            let datagrams: [Data] = muxer.datagrams(
                for: MPEGTSFixtures.unit(bytes: bytes))
            let packets: [[UInt8]] = MPEGTSFixtures.packets(datagrams)
            #expect(packets.allSatisfy { $0.count == 188 })
            let elementary: [UInt8] = MPEGTSFixtures.stream(
                datagrams, pid: MPEGTSMuxer.videoPID)
            #expect(elementary.count >= bytes + 14,
                    "\(bytes) bytes of payload came back short")
            #expect(Array(elementary[14..<(14 + bytes)])
                == MPEGTSFixtures.unit(bytes: bytes).payload,
                    "\(bytes) bytes of payload came back wrong")
        }
    }

    /// How many packets a frame costs, as arithmetic rather than as a
    /// measurement: the first video packet has room for 176 and the rest for 184,
    /// and the whole thing rounds up to a multiple of seven.
    @Test func theDatagramCountIsDerivedFromTheByteCount() {
        var muxer = MPEGTSMuxer()
        let sizes: [Int] = [10, 176, 5000, 40_000]
        for bytes in sizes {
            let pes = bytes + 14
            let video = 1 + Int(ceil(Double(max(0, pes - 176)) / 184.0))
            let expected = Int(ceil(Double(video) / 7.0))
            let datagrams: [Data] = muxer.datagrams(
                for: MPEGTSFixtures.unit(bytes: bytes))
            #expect(datagrams.count == expected,
                    "\(bytes) bytes became \(datagrams.count) datagrams")
        }
    }
}
