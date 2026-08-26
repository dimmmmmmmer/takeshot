import Foundation

/// RTP, because that is what a WebRTC track carries.
///
/// The counterpart of `MPEGTSMuxer` and deliberately its twin: both take the
/// SAME access unit — `MPEGTSMuxer.accessUnit(from:)` is the one seam that turns
/// a `CMSampleBuffer` into (Annex B bytes, 90 kHz timestamp, is-it-a-keyframe) —
/// and both turn it into datagrams. Only the wire differs. SRT wants a transport
/// stream because that is what a set's receivers demux; a browser wants RTP
/// because that is what `RTCPeerConnection` decodes, and no browser has ever
/// demuxed MPEG-TS off a peer connection.
///
/// **Pure Foundation, for the same reason the muxer is.** No CoreMedia, no
/// libdatachannel, no socket: this turns bytes into bytes, so every claim about
/// the wire format is arithmetic a headless suite can check (`RTPPacketizerTests`)
/// rather than a picture somebody looked at on a phone. That matters more here
/// than it did for SRT — the transport underneath is a stub on any machine
/// without the library, so the packetizer is the ONLY half of this feature that
/// can be tested at all.
///
/// **The 90 kHz clock is not a conversion.** RFC 6184 fixes H.264's RTP clock
/// rate at 90 000, which is the transport stream's clock exactly, so
/// `AccessUnit.pts` is already in the right units and the timestamp is that
/// number truncated to 32 bits. Two wire formats agreeing on a clock is luck
/// worth spending a sentence on: it is why one encoder can feed both without
/// either rounding a stamp the other computed.
///
/// **Two packet shapes and no third.** A NAL unit that fits goes out whole
/// (RFC 6184 §5.6, "single NAL unit packet": the payload IS the NAL unit,
/// header byte included). One that does not is split into FU-A fragments
/// (§5.8). STAP-A — several small NAL units bundled into one packet — is
/// deliberately not implemented: it would save one packet per keyframe by
/// bundling the SPS and PPS, and every H.264 receiver has to accept the two
/// shapes here while STAP-A is one more thing to get wrong for 60 bytes a
/// second.
///
/// Confined to the queue its owner runs on: the sequence number is state.
struct RTPH264Packetizer {
    /// The fixed RTP header: version/flags, marker+payload type, sequence
    /// number, timestamp, SSRC. No CSRCs and no extension, so it is never
    /// longer than this.
    static let headerLength = 12

    /// H.264's RTP clock rate, fixed by RFC 6184. The same 90 kHz
    /// `MPEGTSMuxer.clockHz` states, and the reason the two are stated apart is
    /// that they are two standards that agree rather than one number used
    /// twice.
    static let clockHz: Int64 = 90_000

    /// The most payload one packet may carry, in bytes.
    ///
    /// Derived from the smallest MTU this path can meet rather than from the
    /// one a set network usually has: 1280 is IPv6's guaranteed minimum and is
    /// also libdatachannel's own default MTU, and off it come the RTP header
    /// (12), SRTP's authentication tag (10), the UDP header (8) and the IPv6
    /// header (40) — 1210. Rounded down to 1200 so the arithmetic has a margin
    /// nobody has to re-derive when a header gains a field.
    ///
    /// Too LARGE fragments the datagram at the IP layer, which turns one lost
    /// packet into a lost frame; too small costs a header per fragment. This is
    /// the value that never fragments.
    static let maximumPayload = 1200

    /// FU-A, RFC 6184 §5.8: the NAL type that says "this packet is part of one".
    static let fragmentationUnitA: UInt8 = 28

    /// Bytes an FU-A packet spends before the fragment: the FU indicator and
    /// the FU header.
    static let fragmentOverhead = 2

    // MARK: - identity

    /// The synchronization source. One per track, and the browser learns it
    /// from the answer's `a=ssrc` line rather than from anything here.
    let ssrc: UInt32
    /// The dynamic payload type the OFFER named for H.264. Never a constant:
    /// browsers number their codecs differently and the answerer has to use the
    /// offer's number (see `WebRTCOffer`).
    let payloadType: UInt8
    let maximumPayload: Int

    /// Where the next packet's sequence number comes from. 16 bits, wrapping —
    /// a receiver reads a jump in it as a lost packet, so it is per-track state
    /// and not per-frame.
    private(set) var sequenceNumber: UInt16

    init(ssrc: UInt32, payloadType: UInt8,
         maximumPayload: Int = RTPH264Packetizer.maximumPayload,
         firstSequenceNumber: UInt16 = 0) {
        self.ssrc = ssrc
        self.payloadType = payloadType
        // Below the FU-A overhead there is no fragment left to carry and the
        // split would never terminate. Clamped rather than trapped: a caller
        // reading an MTU off a configuration should get a working stream.
        self.maximumPayload = max(Self.fragmentOverhead + 1, maximumPayload)
        self.sequenceNumber = firstSequenceNumber
    }

    // MARK: - packetizing

    /// One access unit as RTP packets, in order.
    ///
    /// **The marker bit is set on the last packet and only there.** It is how a
    /// receiver knows the picture is complete without waiting for the next
    /// frame's timestamp to change, which is a frame of latency on a monitoring
    /// feed. Every packet of one access unit carries the SAME timestamp, marker
    /// or not.
    mutating func packets(for unit: MPEGTSMuxer.AccessUnit) -> [Data] {
        let timestamp = UInt32(truncatingIfNeeded: unit.pts)
        var payloads: [[UInt8]] = []
        for nal in Self.nalUnits(in: unit.payload) {
            payloads += fragments(of: nal)
        }
        return payloads.enumerated().map { index, payload in
            var packet = header(marker: index == payloads.count - 1,
                                timestamp: timestamp)
            packet += payload
            return Data(packet)
        }
    }

    /// One NAL unit as one or more RTP payloads.
    ///
    /// A unit that fits is the payload, untouched — that is the whole of
    /// RFC 6184 §5.6, and it is why a reassembler can tell the two shapes apart
    /// from the first byte alone.
    private func fragments(of nal: ArraySlice<UInt8>) -> [[UInt8]] {
        guard let first = nal.first else { return [] }
        guard nal.count > maximumPayload else { return [Array(nal)] }
        // The original header byte is not sent: its three-bit importance flags
        // ride the FU indicator and its five-bit type rides the FU header, so
        // what is fragmented is the BODY.
        let indicator = (first & 0xE0) | Self.fragmentationUnitA
        let type = first & 0x1F
        let room = maximumPayload - Self.fragmentOverhead
        var out: [[UInt8]] = []
        var body = nal.dropFirst()
        while !body.isEmpty {
            let take = min(room, body.count)
            let start = out.isEmpty
            let end = take == body.count
            let fuHeader = (start ? 0x80 : 0x00) | (end ? 0x40 : 0x00) | type
            out.append([indicator, fuHeader] + body.prefix(take))
            body = body.dropFirst(take)
        }
        return out
    }

    /// The twelve fixed bytes, and the one piece of state in this type.
    private mutating func header(marker: Bool, timestamp: UInt32) -> [UInt8] {
        let sequence = sequenceNumber
        sequenceNumber = sequenceNumber &+ 1
        return [
            0x80, // version 2, no padding, no extension, no CSRCs
            (marker ? 0x80 : 0x00) | (payloadType & 0x7F),
            UInt8(sequence >> 8), UInt8(sequence & 0xFF),
            UInt8((timestamp >> 24) & 0xFF), UInt8((timestamp >> 16) & 0xFF),
            UInt8((timestamp >> 8) & 0xFF), UInt8(timestamp & 0xFF),
            UInt8((ssrc >> 24) & 0xFF), UInt8((ssrc >> 16) & 0xFF),
            UInt8((ssrc >> 8) & 0xFF), UInt8(ssrc & 0xFF),
        ]
    }

    // MARK: - Annex B

    /// The NAL units inside an Annex B access unit, without their start codes.
    ///
    /// Both start-code lengths are accepted. `MPEGTSMuxer` writes four bytes
    /// throughout and says why, so in this app the three-byte case never
    /// arises — but a NAL unit's own bytes cannot contain a start code
    /// (emulation prevention is what those `0x03`s in a parameter set are for),
    /// so scanning for both costs nothing and cannot mis-split.
    ///
    /// A run of zeroes at the END of a unit belongs to the trailing start code
    /// and not to the NAL, which is why the search is for the code rather than
    /// a walk from the previous one's length.
    static func nalUnits(in annexB: [UInt8]) -> [ArraySlice<UInt8>] {
        var out: [ArraySlice<UInt8>] = []
        var start: Int?
        var index = 0
        while index + 2 < annexB.count {
            guard annexB[index] == 0, annexB[index + 1] == 0 else {
                index += 1
                continue
            }
            var codeLength = 0
            if annexB[index + 2] == 1 {
                codeLength = 3
            } else if index + 3 < annexB.count, annexB[index + 2] == 0,
                      annexB[index + 3] == 1 {
                codeLength = 4
            }
            guard codeLength > 0 else {
                index += 1
                continue
            }
            if let open = start, open < index {
                out.append(annexB[open..<index])
            }
            index += codeLength
            start = index
        }
        if let open = start, open < annexB.count {
            out.append(annexB[open...])
        }
        return out.filter { !$0.isEmpty }
    }
}
