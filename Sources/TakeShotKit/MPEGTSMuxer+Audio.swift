import Foundation

/// The second elementary stream: AAC in ADTS, on its own PID, against the same
/// 90 kHz clock the picture is stamped from.
///
/// Its own file for the reason `+Payload` is one — the type is past the
/// body-length ceiling as a single piece — and the seam reads the same way the
/// others do: that file is about what a transport packet CARRIES, this one is
/// about the one thing it carries that is not the picture.
///
/// **Pure Foundation, like the rest of the muxer.** No AudioToolbox, no
/// CoreMedia, no socket: this turns (bytes, a stamp, a rate, a channel count)
/// into datagrams. Every claim about ADTS in `SRTAudioMuxerTests` is arithmetic
/// over bytes against the published field layout, which is what makes a wire
/// format checkable at all on a machine with no receiver on it.
extension MPEGTSMuxer {
    /// The ADTS header: seven bytes with no CRC.
    ///
    /// **Why the sound is framed at all when the picture is not.** H.264's
    /// parameter sets go in the stream on a keyframe and a receiver reads the
    /// raster out of them; AAC has no such thing in the elementary stream, so
    /// the rate and the channel count travel in a header on every access unit.
    /// That is exactly what makes `stream_type` 0x0F self-describing, and why a
    /// director's VLC opened twenty minutes into a setup gets sound rather than
    /// a stream it cannot configure a decoder for.
    ///
    /// The two fields that could disagree with the encoder come from the access
    /// unit itself (see `LiveAudioEncoder.AccessUnit`), never from a setting.
    static func adts(payloadBytes: Int, sampleRate: Int,
                     channels: Int) -> [UInt8] {
        let frequency = UInt8(samplingFrequencyIndex(sampleRate))
        // ADTS states the channel COUNT as a configuration index, and 1 to 6 are
        // the count itself. The tap only ever produces one or two (see
        // `CapturePipeline.stereoChannelIndices`); the clamp is a bound, not a
        // conversion, and anything outside it would be a channel layout ADTS
        // has no way to name.
        let configuration = UInt8(min(max(channels, 1), 6))
        let length = payloadBytes + adtsHeaderBytes
        return [
            0xFF,
            // MPEG-4, layer 00, no CRC — which is what makes the header seven
            // bytes rather than nine.
            0xF1,
            // profile 01 (AAC-LC, stated as the object type minus one), the
            // rate, no private bit, then the top bit of the channel index.
            (0x01 << 6) | (frequency << 2) | (configuration >> 2),
            ((configuration & 0x03) << 6) | UInt8((length >> 11) & 0x03),
            UInt8((length >> 3) & 0xFF),
            // the low three bits of the length, then the top five of a buffer
            // fullness written all-ones: the VBR value, and the only honest one
            // for an encoder whose rate control we do not model
            (UInt8(length & 0x07) << 5) | 0x1F,
            0xFC,
        ]
    }

    /// Bytes an ADTS header without CRC takes.
    static let adtsHeaderBytes = 7

    /// The rate as ADTS names it — an index into the format's own table, not a
    /// number. 48 kHz is 3 and is the only one this app's audio path produces
    /// (`PCMAudio` builds every buffer at 48 kHz); the rest of the table is
    /// here so a rate that somehow was not 48 kHz is stated correctly rather
    /// than silently as 48.
    static func samplingFrequencyIndex(_ rate: Int) -> Int {
        let table = [96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000,
                     22_050, 16_000, 12_000, 11_025, 8_000, 7_350]
        return table.firstIndex(of: rate) ?? 3
    }

    /// The audio PES packet: one ADTS-framed access unit with one stamp on it.
    ///
    /// **`PES_packet_length` is written, unlike the video one's.** Zero means
    /// "until the next PES starts" and is legal only for a video stream; an
    /// audio PES has to state its length, and it can — an access unit is a few
    /// hundred bytes where a keyframe is tens of thousands.
    ///
    /// The alignment indicator is set, and it is a true statement rather than a
    /// habit: this PES begins exactly on an ADTS syncword, so a receiver that
    /// has just joined can start parsing at the first payload byte it sees
    /// instead of scanning for one.
    static func audioPES(payload: [UInt8], pts: Int64) -> [UInt8] {
        var out: [UInt8] = [0x00, 0x00, 0x01, 0xC0]
        // everything after the length field: the two flag bytes, the header
        // length byte, the five of PTS, and the unit itself
        let length = 3 + 5 + payload.count
        out.append(UInt8((length >> 8) & 0xFF))
        out.append(UInt8(length & 0xFF))
        // '10' marker, no scrambling, no priority, ALIGNED, not copyrighted,
        // not original
        out.append(0x84)
        // PTS present, DTS absent: audio is never reordered, so a DTS would be
        // the same number written twice — the picture's reason, and this stream
        // has it by construction rather than by a setting.
        out.append(0x80)
        out.append(0x05)
        out.append(contentsOf: timestamp(pts, marker: 0x2))
        out.append(contentsOf: payload)
        return out
    }

    /// One encoded access unit into the pending run, and whatever whole
    /// datagrams that completes.
    ///
    /// Returns [] most of the time and that is the design rather than a
    /// failure: three transport packets per unit against seven to a datagram
    /// means two units out of three complete nothing on their own, and the
    /// alternative is 280 kbit/s of null packets (see
    /// `MPEGTSMuxer.pendingPackets`). Nothing is ever LOST by it — the next
    /// video frame flushes everything held.
    mutating func datagrams(forAudio unit: LiveAudioEncoder.AccessUnit)
        -> [Data] {
        guard !unit.payload.isEmpty else { return [] }
        let framed = Self.adts(payloadBytes: unit.payload.count,
                               sampleRate: unit.sampleRate,
                               channels: unit.channels) + unit.payload
        hold(elementary(Self.audioPES(payload: framed, pts: unit.ticks),
                        pid: Self.audioPID, leading: []))
        return takeWholeDatagrams()
    }
}
