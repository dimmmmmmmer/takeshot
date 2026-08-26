import Foundation

/// What goes inside the transport packets: the PES wrapper, the program clock,
/// and the two tables that tell a receiver what it is looking at.
///
/// Split from `MPEGTSMuxer` because the type was past the body-length ceiling as
/// one piece, and this is the seam that reads best — the other file is about
/// packets and this one is about what they carry.
extension MPEGTSMuxer {
    // MARK: - the elementary stream

    /// The PES packet: one access unit with one timestamp on it.
    ///
    /// `PES_packet_length` is written as ZERO, which for a video stream means
    /// "until the next one starts" and is the only legal choice here — the field
    /// is 16 bits and a 1080p keyframe at any sensible bitrate goes past 65535.
    static func pes(payload: [UInt8], pts: Int64) -> [UInt8] {
        var out: [UInt8] = [0x00, 0x00, 0x01, 0xE0, 0x00, 0x00]
        // '10' marker, no scrambling, no priority, no alignment flag, not
        // copyrighted, not original.
        out.append(0x80)
        // PTS present, DTS absent. See `AccessUnit.pts`.
        out.append(0x80)
        out.append(0x05)
        out.append(contentsOf: timestamp(pts, marker: 0x2))
        out.append(contentsOf: payload)
        return out
    }

    /// A 33-bit timestamp in the five bytes the standard spreads it over.
    ///
    /// The odd shape is not ours: the bits are interleaved with set-to-one
    /// padding so that no byte of a header can ever look like a start code.
    static func timestamp(_ value: Int64, marker: UInt8) -> [UInt8] {
        let ticks = UInt64(bitPattern: value) & 0x1_FFFF_FFFF
        return [
            (marker << 4) | UInt8((ticks >> 30) & 0x07) << 1 | 0x01,
            UInt8((ticks >> 22) & 0xFF),
            UInt8((ticks >> 15) & 0x7F) << 1 | 0x01,
            UInt8((ticks >> 7) & 0xFF),
            UInt8(ticks & 0x7F) << 1 | 0x01,
        ]
    }

    /// The video PES split across transport packets.
    ///
    /// The first packet carries the program clock and, on a keyframe, the
    /// random-access indicator; the last is padded out through its adaptation
    /// field, because a transport packet is 188 bytes and there is no such thing
    /// as a short one.
    mutating func video(_ pes: [UInt8], pcr: Int64,
                        randomAccess: Bool) -> [[UInt8]] {
        elementary(pes, pid: Self.videoPID,
                   leading: Self.clockField(pcr: pcr,
                                            randomAccess: randomAccess))
    }

    /// A PES split across transport packets on one PID, with `leading` in the
    /// adaptation field of the first packet and nothing in the rest.
    ///
    /// Shared between the two elementary streams rather than written twice.
    /// The difference between them is exactly `leading` — the picture carries
    /// the program clock and the sound does not, because a program has ONE
    /// clock reference and the PMT names which PID it is on. Everything else,
    /// the splitting and the tail padding, is the same arithmetic and a second
    /// copy of it is a second place for the stuffing to be one byte out.
    mutating func elementary(_ pes: [UInt8], pid: UInt16,
                             leading: [UInt8]) -> [[UInt8]] {
        var out: [[UInt8]] = []
        var offset = 0
        var first = true
        while offset < pes.count {
            let lead = first ? leading : []
            let room = Self.payloadPerPacket - lead.count
            let take = min(room, pes.count - offset)
            let adaptation = lead + Self.stuffing(bytes: room - take, after: lead)
            out.append(packet(pid: pid, start: first,
                              adaptation: adaptation,
                              payload: pes[offset..<(offset + take)]))
            offset += take
            first = false
        }
        return out
    }

    /// The adaptation field carrying the program clock reference.
    ///
    /// **PCR is the presentation time, exactly.** A muxer feeding a broadcast
    /// chain sets it behind the picture to give a decoder headroom; this one is
    /// feeding a monitor over a link whose whole point is that ITS buffer is the
    /// operator's dial, and a second buffer inside the stream would add latency
    /// the latency setting does not account for. One per access unit is also
    /// comfortably inside the standard's 100 ms.
    static func clockField(pcr: Int64, randomAccess: Bool) -> [UInt8] {
        let base = UInt64(bitPattern: pcr) & 0x1_FFFF_FFFF
        return [
            0x07, // one flags byte plus six of PCR
            randomAccess ? 0x50 : 0x10,
            UInt8((base >> 25) & 0xFF),
            UInt8((base >> 17) & 0xFF),
            UInt8((base >> 9) & 0xFF),
            UInt8((base >> 1) & 0xFF),
            UInt8((base & 0x01) << 7) | 0x7E, // low bit, then the reserved six
            0x00, // 27 MHz extension: zero, the clock is the 90 kHz one
        ]
    }

    // MARK: - the tables

    /// One program, and where to find its map.
    mutating func programAssociation() -> [UInt8] {
        var body: [UInt8] = [0x00, 0xB0, 0x0D]
        body += [0x00, 0x01, 0xC1, 0x00, 0x00]
        body += [UInt8(Self.programNumber >> 8),
                 UInt8(Self.programNumber & 0xFF),
                 0xE0 | UInt8((Self.pmtPID >> 8) & 0x1F),
                 UInt8(Self.pmtPID & 0xFF)]
        return tablePacket(body, on: Self.patPID)
    }

    /// The program's streams, and which of them carries its clock.
    ///
    /// One entry or two, on `carriesAudio`. The section length follows from the
    /// count rather than being written twice: nine bytes of program header,
    /// five per elementary stream, four of CRC. That is 0x12 for the picture
    /// alone — byte for byte what this table was before there was any sound —
    /// and 0x17 with the audio stream on it.
    ///
    /// The video PID stays the clock reference in both. A program has one, and
    /// moving it because a second stream appeared would restate the timing of
    /// the feed for a change that is not about timing.
    mutating func programMap() -> [UInt8] {
        var streams: [UInt8] = Self.elementaryStream(type: Self.streamTypeH264,
                                                     pid: Self.videoPID)
        if carriesAudio {
            streams += Self.elementaryStream(type: Self.streamTypeAAC,
                                             pid: Self.audioPID)
        }
        let sectionLength = 9 + streams.count + 4
        var body: [UInt8] = [0x02, 0xB0, UInt8(sectionLength)]
        body += [UInt8(Self.programNumber >> 8),
                 UInt8(Self.programNumber & 0xFF), 0xC1, 0x00, 0x00]
        body += [0xE0 | UInt8((Self.videoPID >> 8) & 0x1F),
                 UInt8(Self.videoPID & 0xFF), 0xF0, 0x00]
        body += streams
        return tablePacket(body, on: Self.pmtPID)
    }

    /// One entry in the PMT's stream loop: what it is, where it is, and no
    /// descriptors.
    static func elementaryStream(type: UInt8, pid: UInt16) -> [UInt8] {
        [type, 0xE0 | UInt8((pid >> 8) & 0x1F), UInt8(pid & 0xFF), 0xF0, 0x00]
    }

    /// A section as a whole packet: pointer field, section, CRC, then 0xFF to the
    /// end. Both tables fit one packet several times over.
    mutating func tablePacket(_ body: [UInt8], on pid: UInt16) -> [UInt8] {
        var payload: [UInt8] = [0x00]
        payload += body
        let crc = Self.crc32(body)
        payload += [UInt8((crc >> 24) & 0xFF), UInt8((crc >> 16) & 0xFF),
                    UInt8((crc >> 8) & 0xFF), UInt8(crc & 0xFF)]
        payload += [UInt8](repeating: 0xFF,
                           count: Self.payloadPerPacket - payload.count)
        return packet(pid: pid, start: true, adaptation: [],
                      payload: payload[...])
    }

    /// CRC-32/MPEG-2: the unreflected, un-xored variant the tables use.
    ///
    /// Bitwise rather than table-driven on purpose — it runs twice per keyframe
    /// over twenty bytes, and a 1 KB table would be more of this file than the
    /// muxer is. `SRTMuxerTests` pins it against the published check value for
    /// the algorithm rather than against whatever this code happens to produce,
    /// which is the difference between a checksum and a coincidence.
    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte) << 24
            for _ in 0..<8 {
                crc = crc & 0x8000_0000 != 0
                    ? (crc << 1) ^ 0x04C1_1DB7 : crc << 1
            }
        }
        return crc
    }
}
