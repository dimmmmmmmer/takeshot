import Foundation

/// MPEG-TS, because that is what an SRT link carries.
///
/// This is the piece the NDI output never needed, and the one that makes SRT a
/// different feature rather than a different cable. NDI took FRAMES — the
/// display buffer's own bytes, handed over uncopied, no conversion anywhere in
/// the path. SRT takes a BYTE STREAM, and the byte stream every SRT receiver on
/// a set expects is an MPEG-2 transport stream: 188-byte packets, a program
/// table, a program clock, and the encoded picture inside PES packets.
///
/// **Pure Foundation, deliberately.** No CoreMedia, no VideoToolbox, no socket:
/// this type turns (bytes, timestamp, is-it-a-keyframe) into datagrams and
/// nothing else. That is what makes a wire format testable at all — every claim
/// in `SRTMuxerTests` is arithmetic over bytes rather than a picture somebody
/// looked at, and the one number the whole design rests on (1316 = 188 × 7) is
/// checked rather than trusted.
///
/// **Every datagram is exactly 1316 bytes**, padded with null packets when an
/// access unit does not fill the last one. That is libsrt's own
/// `SRT_LIVE_DEF_PLSIZE`, and in live mode one message is one datagram — so a
/// constant size is what the transport is built around. The padding costs half a
/// datagram per frame on average, about 16 kbit/s at 25 fps, against the
/// alternative of handing SRT a short message and hoping the far end's demuxer
/// is relaxed about it.
///
/// Confined to `SRTMirror`'s queue: the continuity counters are state.
struct MPEGTSMuxer {
    /// One encoded picture, in Annex B, ready to be packetised.
    struct AccessUnit: Equatable, Sendable {
        /// Annex B bytes: start code, NAL unit, start code, NAL unit…
        /// Parameter sets belong in here on a keyframe — see `SRTVideoEncoder`,
        /// which is what knows where they come from.
        var payload: [UInt8]
        /// Presentation time on the 90 kHz clock the transport stream uses.
        ///
        /// There is no separate decode time, and nothing is missing: frame
        /// reordering is off in the encoder, so presentation order IS coding
        /// order and a DTS would be the same number written twice.
        var pts: Int64
        /// Whether a receiver can start decoding here. Drives three things at
        /// once: the tables are resent, the random-access indicator is set, and
        /// the parameter sets are in `payload`.
        var isKeyframe: Bool
    }

    // MARK: - the numbers

    /// A transport packet. Not negotiable — it is the format.
    static let packetLength = 188
    /// Packets to a datagram.
    static let packetsPerDatagram = 7
    /// 1316: libsrt's `SRT_LIVE_DEF_PLSIZE`, which is 188 × 7 for exactly this
    /// reason — an MPEG-TS payload that fits one MTU with SRT's own header on.
    static let datagramLength = packetLength * packetsPerDatagram
    /// What a packet has left once its four-byte header is on.
    static let payloadPerPacket = packetLength - 4

    static let syncByte: UInt8 = 0x47
    static let patPID: UInt16 = 0x0000
    static let pmtPID: UInt16 = 0x1000
    static let videoPID: UInt16 = 0x0100
    /// The second elementary stream: the sound off the pipeline's stereo tap.
    ///
    /// Its own PID and not a second thing on the video one — that is what an
    /// elementary stream IS. 0x0101 sits next to the picture's for the same
    /// reason the two are numbered at all: a demuxer's log reads as one program
    /// with two streams rather than as two unrelated numbers.
    static let audioPID: UInt16 = 0x0101
    /// A packet with no information in it, which is how a datagram is filled.
    static let nullPID: UInt16 = 0x1FFF
    static let programNumber: UInt16 = 1
    /// H.264 in a transport stream. HEVC would be 0x24; `SRTVideoEncoder` says
    /// why this stream is not that.
    static let streamTypeH264: UInt8 = 0x1B
    /// AAC with ADTS framing. 0x11 would be LATM, which fewer receivers take
    /// without being told; see `LiveAudioEncoder` for why the far end decides
    /// this rather than the codec does.
    static let streamTypeAAC: UInt8 = 0x0F
    /// The transport stream's clock, fixed by the standard at 90 kHz. It is why
    /// the encoder is asked for timestamps on that timescale in the first place
    /// rather than converting here and rounding twice.
    static let clockHz: Int64 = 90_000

    // MARK: - state

    /// Continuity counter per PID: four bits, wrapping. A receiver reads a jump
    /// in it as a lost packet, so it is per-PID state and not per-frame.
    private var continuity: [UInt16: UInt8] = [:]

    /// Whether the program has a second elementary stream in it.
    ///
    /// The PMT is built from this, so it is not a decoration: a program map
    /// that DECLARES an audio PID nothing ever feeds is a receiver waiting for
    /// sound that is not coming, which several of them answer by holding the
    /// picture too. Set by whoever knows whether an audio encoder exists (see
    /// `SRTMirror.setCarriesAudio`), and a change only reaches the wire on
    /// the next keyframe — which is when the tables are resent, and why that
    /// setter asks for one.
    var carriesAudio = false

    /// Packets muxed but not yet in a whole datagram.
    ///
    /// **The audio leg is what this is for, and it costs the picture nothing.**
    /// Every datagram is 1316 bytes whatever is in it, so an access unit that
    /// does not fill the last one is padded with nulls — half a datagram per
    /// unit on average. For a picture that is one unit per FRAME and about
    /// 16 kbit/s at 25 fps. For sound it is one unit per 21.3 ms and about
    /// 280 kbit/s of nothing, which is more than the audio stream itself.
    ///
    /// So audio packets go in here and only WHOLE datagrams leave, while a
    /// video unit takes everything pending with it and pads once. The padding
    /// stays exactly what it was before there was any sound — half a datagram
    /// per frame — and what audio pays instead is up to one video frame of
    /// buffering, which a receiver absorbs against the PTS the unit already
    /// carries. Never more than six packets are held, because seven is a
    /// datagram and a datagram leaves.
    private var pendingPackets: [[UInt8]] = []

    init() {}

    /// One access unit as whole datagrams.
    ///
    /// The tables ride with the KEYFRAME rather than on a timer of their own. A
    /// receiver that has tables and no keyframe cannot show a picture, and one
    /// that has a keyframe and no tables cannot either — so the two arrive
    /// together and the join time is one keyframe interval, which is the number
    /// the operator would have been waiting on anyway.
    ///
    /// **The picture flushes.** Whatever audio is pending rides out with this
    /// frame and the tail is padded, so a video unit never waits for a sound
    /// unit — the feed the operator is replacing a cable with is the picture,
    /// and it keeps the latency it had.
    mutating func datagrams(for unit: AccessUnit) -> [Data] {
        var packets: [[UInt8]] = []
        if unit.isKeyframe {
            packets.append(programAssociation())
            packets.append(programMap())
        }
        packets += video(Self.pes(payload: unit.payload, pts: unit.pts),
                         pcr: unit.pts, randomAccess: unit.isKeyframe)
        pendingPackets += packets
        let out = Self.grouped(pendingPackets)
        pendingPackets.removeAll(keepingCapacity: true)
        return out
    }

    /// Whole datagrams out of what is pending, leaving the remainder. The audio
    /// side of the trade above; see `MPEGTSMuxer+Audio`.
    mutating func takeWholeDatagrams() -> [Data] {
        let whole = pendingPackets.count / Self.packetsPerDatagram
        guard whole > 0 else { return [] }
        let taken = whole * Self.packetsPerDatagram
        let out = Self.grouped(Array(pendingPackets[0..<taken]))
        pendingPackets.removeFirst(taken)
        return out
    }

    /// Packets muxed and not yet sent. For the tests: "audio is never padded"
    /// and "the picture always flushes" are both claims about this number, and
    /// a muxer that held nothing and one that held six are indistinguishable
    /// from the datagrams alone.
    var heldPackets: Int { pendingPackets.count }

    /// Add packets to the pending run. Internal rather than private because the
    /// audio half of this type is a file along, for the body-length reason the
    /// payload half already is.
    mutating func hold(_ packets: [[UInt8]]) {
        pendingPackets += packets
    }

    /// Packets in groups of seven, the tail padded so every datagram is the size
    /// the socket was configured for.
    static func grouped(_ packets: [[UInt8]]) -> [Data] {
        var out: [Data] = []
        var index = 0
        while index < packets.count {
            var datagram = Data(capacity: datagramLength)
            for slot in 0..<packetsPerDatagram {
                let source = index + slot
                datagram.append(contentsOf: source < packets.count
                    ? packets[source] : nullPacket)
            }
            out.append(datagram)
            index += packetsPerDatagram
        }
        return out
    }

    /// A packet that says nothing. PID 0x1FFF and no adaptation field; a
    /// receiver discards it without looking any further.
    static let nullPacket: [UInt8] = [
        MPEGTSMuxer.syncByte,
        UInt8(MPEGTSMuxer.nullPID >> 8),
        UInt8(MPEGTSMuxer.nullPID & 0xFF),
        0x10,
    ] + [UInt8](repeating: 0xFF, count: MPEGTSMuxer.payloadPerPacket)

    /// One transport packet, 188 bytes by construction.
    ///
    /// Internal rather than private because the payload half of this muxer lives
    /// in `MPEGTSMuxer+Payload.swift` — the type was over the body-length ceiling
    /// as one piece. The continuity counters stay private, and this is the only
    /// thing that touches them.
    mutating func packet(pid: UInt16, start: Bool, adaptation: [UInt8],
                         payload: ArraySlice<UInt8>) -> [UInt8] {
        let counter = continuity[pid, default: 0]
        continuity[pid] = (counter + 1) & 0x0F
        var out: [UInt8] = [
            Self.syncByte,
            (start ? 0x40 : 0x00) | UInt8((pid >> 8) & 0x1F),
            UInt8(pid & 0xFF),
            (adaptation.isEmpty ? 0x10 : 0x30) | counter,
        ]
        // The adaptation field arrives with its own length byte on it, from
        // `clockField` or from `stuffing` — but a clock field that has had
        // stuffing appended needs that length corrected, because the two are ONE
        // field and not two. Fixing it here rather than at either producer is
        // what keeps the two cases from having to know about each other.
        if !adaptation.isEmpty {
            var field = adaptation
            field[0] = UInt8(field.count - 1)
            out.append(contentsOf: field)
        }
        out.append(contentsOf: payload)
        return out
    }

    /// Bytes of nothing, in whichever of the two shapes the format allows.
    ///
    /// One spare byte cannot be an adaptation field with a flags byte in it, so
    /// the format spends it on a length of zero instead. That special case is the
    /// only reason this is a function.
    static func stuffing(bytes: Int, after adaptation: [UInt8]) -> [UInt8] {
        guard bytes > 0 else { return [] }
        if !adaptation.isEmpty {
            return [UInt8](repeating: 0xFF, count: bytes)
        }
        if bytes == 1 { return [0x00] }
        return [UInt8(bytes - 1), 0x00]
            + [UInt8](repeating: 0xFF, count: bytes - 2)
    }
}
