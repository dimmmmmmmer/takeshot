import Foundation
import Testing

@testable import TakeShotKit

/// The SECOND elementary stream, checked as bytes.
///
/// `SRTMuxerTests` is this suite's sibling and its reasoning applies unchanged:
/// a wire format cannot be verified by looking at a picture, and here there is
/// not even a picture to look at — a receiver that plays the sound is evidence
/// that nothing is badly wrong and no evidence at all about the fields a strict
/// demuxer reads. So everything here is arithmetic against the published field
/// layout.
///
/// **What this suite cannot answer** is lip sync. Both streams are stamped
/// against one `LiveClock`, and the arithmetic below pins that the sound's
/// stamps advance by exactly one access unit each — but the OFFSET between the
/// two paths' latencies is a property of a decoder, and only a real receiver
/// shows its size.
enum AudioMuxFixtures {
    /// An access unit of `bytes` synthetic payload. Not real AAC — the muxer
    /// never looks inside one, and a fixture pretending to be sound would only
    /// make the failures harder to read.
    static func unit(bytes: Int, ticks: Int64 = 0,
                     channels: Int = 2) -> LiveAudioEncoder.AccessUnit {
        LiveAudioEncoder.AccessUnit(
            payload: (0..<bytes).map { UInt8($0 % 251) }, ticks: ticks,
            sampleRate: LiveAudioEncoder.sampleRate, channels: channels)
    }

    /// A muxer already declaring audio, which is the state it reaches on the
    /// first unit that actually arrives (see `SRTMirror.deliver(audio:)`).
    static func muxer() -> MPEGTSMuxer {
        var muxer = MPEGTSMuxer()
        muxer.carriesAudio = true
        return muxer
    }

    /// The PTS of every audio access unit in a run of datagrams, in order.
    static func timestamps(_ datagrams: [Data]) -> [Int64] {
        MPEGTSFixtures.packets(datagrams)
            .filter {
                MPEGTSFixtures.pid(of: $0) == MPEGTSMuxer.audioPID
                    && MPEGTSFixtures.startsUnit($0)
            }
            .compactMap { packet -> Int64? in
                let bytes: [UInt8] = MPEGTSFixtures.payload(of: packet)
                // 6 bytes of PES header, 3 of flags and length, then the PTS
                guard bytes.count >= 14 else { return nil }
                return MPEGTSFixtures.timestamp(Array(bytes[9..<14]))
            }
    }
}

/// The ADTS header, field by field.
///
/// The picture needs no framing of this kind — H.264's parameter sets are in
/// the stream on a keyframe — and AAC has nothing equivalent, so these seven
/// bytes are the whole of what tells a receiver what to configure a decoder
/// for. Getting the rate index or the channel configuration wrong produces
/// sound at the wrong speed rather than an error anywhere.
@Suite struct ADTSHeaderTests {
    @Test func theHeaderIsSevenBytesAndSaysSo() {
        #expect(MPEGTSMuxer.adtsHeaderBytes == 7)
        let header: [UInt8] = MPEGTSMuxer.adts(payloadBytes: 300,
                                               sampleRate: 48_000, channels: 2)
        #expect(header.count == 7)
        // syncword 0xFFF, then MPEG-4, layer 00, protection absent — which is
        // what makes it seven bytes rather than nine.
        #expect(header[0] == 0xFF)
        #expect(header[1] == 0xF1)
    }

    @Test func theProfileIsAACLowComplexity() {
        let header: [UInt8] = MPEGTSMuxer.adts(payloadBytes: 300,
                                               sampleRate: 48_000, channels: 2)
        // Two bits, stated as the audio object type MINUS ONE: AAC-LC is object
        // type 2, so the field is 1.
        #expect(header[2] >> 6 == 0x01)
    }

    /// 48 kHz is index 3 — the only rate this app's audio path produces, and
    /// the one number in the header that turns wrong sound into slow sound.
    @Test func theRateIsAnIndexAndFortyEightIsThree() {
        #expect(MPEGTSMuxer.samplingFrequencyIndex(48_000) == 3)
        #expect(MPEGTSMuxer.samplingFrequencyIndex(44_100) == 4)
        #expect(MPEGTSMuxer.samplingFrequencyIndex(96_000) == 0)
        // Anything not in the table falls back to 48 kHz rather than to an
        // index that means something else.
        #expect(MPEGTSMuxer.samplingFrequencyIndex(37_000) == 3)
        let header: [UInt8] = MPEGTSMuxer.adts(payloadBytes: 300,
                                               sampleRate: 48_000, channels: 2)
        #expect((header[2] >> 2) & 0x0F == 3)
    }

    /// One and two both travel, because the tap produces both: a mask with a
    /// single enabled channel is a MONO feed by design, not a doubled one.
    @Test func theChannelConfigurationIsTheCount() {
        for channels in 1...6 {
            let header: [UInt8] = MPEGTSMuxer.adts(payloadBytes: 300,
                                                   sampleRate: 48_000,
                                                   channels: channels)
            let configuration = Int((header[2] & 0x01) << 2)
                + Int((header[3] >> 6) & 0x03)
            #expect(configuration == channels,
                    "\(channels) channels stated as \(configuration)")
        }
    }

    /// The length field counts the header itself, which is the field a demuxer
    /// walks the stream by — one byte out and every unit after it is lost.
    @Test func theLengthCountsTheHeaderAndThePayload() {
        for payload in [1, 7, 200, 383, 1_000, 8_000] {
            let header: [UInt8] = MPEGTSMuxer.adts(payloadBytes: payload,
                                                   sampleRate: 48_000,
                                                   channels: 2)
            let length = Int(header[3] & 0x03) << 11
                | Int(header[4]) << 3 | Int(header[5] >> 5)
            #expect(length == payload + 7,
                    "\(payload) bytes framed as \(length)")
        }
    }

    /// Buffer fullness is written all-ones, which is the VBR value — the only
    /// honest one for an encoder whose rate control the app does not model.
    @Test func theBufferFullnessIsTheVariableRateValue() {
        let header: [UInt8] = MPEGTSMuxer.adts(payloadBytes: 300,
                                               sampleRate: 48_000, channels: 2)
        let fullness = Int(header[5] & 0x1F) << 6 | Int(header[6] >> 2)
        #expect(fullness == 0x7FF)
        // …and exactly one raw data block in the frame.
        #expect(header[6] & 0x03 == 0)
    }
}

/// The audio elementary stream: its PID, its PES, and the program map that
/// declares it.
@Suite struct SRTAudioStreamTests {
    /// Sound is its own PID, and the picture's is untouched.
    @Test func theSoundIsOnItsOwnPID() {
        #expect(MPEGTSMuxer.audioPID != MPEGTSMuxer.videoPID)
        #expect(MPEGTSMuxer.audioPID == 0x0101)
        #expect(MPEGTSMuxer.streamTypeAAC == 0x0F)

        var muxer = AudioMuxFixtures.muxer()
        // enough units to complete a datagram on the audio PID alone
        var datagrams: [Data] = []
        for index in 0..<8 {
            datagrams += muxer.datagrams(
                forAudio: AudioMuxFixtures.unit(bytes: 350,
                                                ticks: Int64(index) * 1920))
        }
        let pids = Set(MPEGTSFixtures.packets(datagrams)
            .map { MPEGTSFixtures.pid(of: $0) })
        #expect(pids.subtracting([MPEGTSMuxer.audioPID,
                                  MPEGTSMuxer.nullPID]).isEmpty,
                "audio units put packets on \(pids)")
    }

    /// The PES is an audio one, states its own length, and says its payload is
    /// aligned — all three of which the video PES deliberately does not.
    @Test func theAudioPESStatesItsLengthAndItsAlignment() {
        let payload: [UInt8] = (0..<300).map { UInt8($0 % 251) }
        let pes: [UInt8] = MPEGTSMuxer.audioPES(payload: payload, pts: 90_000)
        #expect(Array(pes[0..<3]) == [0x00, 0x00, 0x01])
        #expect(pes[3] == 0xC0, "the stream id is not an audio one")
        let length = Int(pes[4]) << 8 | Int(pes[5])
        #expect(length == 8 + payload.count)
        #expect(length == pes.count - 6, "the length does not match the packet")
        // data_alignment_indicator, which the video PES leaves clear
        #expect(pes[6] & 0x04 != 0)
        // PTS present, DTS absent, five bytes of it
        #expect(pes[7] == 0x80)
        #expect(pes[8] == 0x05)
        #expect(MPEGTSFixtures.timestamp(Array(pes[9..<14])) == 90_000)
        #expect(Array(pes[14...]) == payload)
    }

    /// The stamps come out the way they went in, on the same clock the picture
    /// is on. One access unit is 1920 ticks and the series is exact.
    @Test func theStampsSurviveAndAdvanceByOneAccessUnit() {
        var muxer = AudioMuxFixtures.muxer()
        var datagrams: [Data] = []
        for index in 0..<12 {
            datagrams += muxer.datagrams(
                forAudio: AudioMuxFixtures.unit(
                    bytes: 350,
                    ticks: 500_000 + Int64(index)
                        * LiveAudioEncoder.ticksPerAccessUnit))
        }
        // whatever is still pending goes out with the next picture
        datagrams += muxer.datagrams(for: MPEGTSFixtures.unit(bytes: 4_000))
        let stamps: [Int64] = AudioMuxFixtures.timestamps(datagrams)
        #expect(stamps.count == 12, "\(stamps.count) of 12 units carried a stamp")
        for (index, stamp) in stamps.enumerated() {
            #expect(stamp == 500_000 + Int64(index) * 1920,
                    "unit \(index) stamped \(stamp)")
        }
    }

    /// The payload survives packetisation byte for byte, ADTS header and all.
    @Test func theFramedUnitSurvivesPacketisationExactly() {
        var muxer = AudioMuxFixtures.muxer()
        let unit = AudioMuxFixtures.unit(bytes: 700, ticks: 12_345)
        var datagrams: [Data] = muxer.datagrams(forAudio: unit)
        datagrams += muxer.datagrams(for: MPEGTSFixtures.unit(bytes: 4_000))
        let stream: [UInt8] = MPEGTSFixtures.stream(datagrams,
                                                    pid: MPEGTSMuxer.audioPID)
        let header: [UInt8] = MPEGTSMuxer.adts(payloadBytes: 700,
                                               sampleRate: 48_000, channels: 2)
        // 6 PES header bytes, 3 flag/length bytes, 5 of PTS, then the frame
        let carried: [UInt8] = Array(stream[14..<(14 + 7 + 700)])
        #expect(Array(carried[0..<7]) == header)
        #expect(Array(carried[7...]) == unit.payload)
    }

    /// An empty unit is refused rather than framed: a zero-length AAC frame is
    /// a header claiming seven bytes of nothing, which a demuxer walks straight
    /// past the end of.
    @Test func anEmptyUnitProducesNothing() {
        var muxer = AudioMuxFixtures.muxer()
        #expect(muxer.datagrams(forAudio:
            AudioMuxFixtures.unit(bytes: 0)).isEmpty)
        #expect(muxer.heldPackets == 0)
    }

    /// Audio packets carry NO program clock: a program has one clock reference
    /// and the PMT names the video PID as it.
    @Test func theSoundCarriesNoProgramClock() {
        var muxer = AudioMuxFixtures.muxer()
        var datagrams: [Data] = []
        for index in 0..<8 {
            datagrams += muxer.datagrams(
                forAudio: AudioMuxFixtures.unit(bytes: 350,
                                                ticks: Int64(index) * 1920))
        }
        for packet in MPEGTSFixtures.packets(datagrams)
        where MPEGTSFixtures.pid(of: packet) == MPEGTSMuxer.audioPID {
            guard packet[3] & 0x20 != 0, packet[4] > 0 else { continue }
            #expect(packet[5] & 0x10 == 0,
                    "an audio packet is carrying a PCR flag")
        }
    }

    /// Continuity counts on the audio PID independently of the picture's — a
    /// receiver reads a jump in it as a lost packet.
    @Test func continuityCountsOnTheSoundsOwnPID() {
        var muxer = AudioMuxFixtures.muxer()
        var datagrams: [Data] = []
        for index in 0..<40 {
            datagrams += muxer.datagrams(
                forAudio: AudioMuxFixtures.unit(bytes: 350,
                                                ticks: Int64(index) * 1920))
        }
        let counters: [UInt8] = MPEGTSFixtures.packets(datagrams)
            .filter { MPEGTSFixtures.pid(of: $0) == MPEGTSMuxer.audioPID }
            .map { MPEGTSFixtures.continuity(of: $0) }
        #expect(counters.count > 16, "not enough packets to see a wrap")
        for (index, counter) in counters.enumerated() {
            #expect(counter == UInt8(index % 16),
                    "packet \(index) counted \(counter)")
        }
    }
}

/// **The program map with and without sound**, which is the one table a
/// receiver reads before it will decode anything at all.
@Suite struct SRTProgramMapTests {
    private static func map(carryingAudio: Bool) -> [UInt8] {
        var muxer = MPEGTSMuxer()
        muxer.carriesAudio = carryingAudio
        let datagrams: [Data] = muxer.datagrams(
            for: MPEGTSFixtures.unit(bytes: 100, keyframe: true))
        return MPEGTSFixtures.stream(datagrams, pid: MPEGTSMuxer.pmtPID)
    }

    /// **With no sound the table is byte for byte what it always was.** The
    /// regression guard for every receiver already pointed at this app: a
    /// program map that changed shape because a feature exists somewhere else
    /// is a feature that broke the picture.
    @Test func withoutAudioTheMapIsUnchanged() {
        let map: [UInt8] = Self.map(carryingAudio: false)
        #expect(map[1] == 0x02)
        #expect(map[2] == 0xB0)
        #expect(map[3] == 0x12, "the one-stream PMT is no longer 18 bytes")
        #expect(map[13] == MPEGTSMuxer.streamTypeH264)
        let elementary: UInt16 = (UInt16(map[14] & 0x1F) << 8) | UInt16(map[15])
        #expect(elementary == MPEGTSMuxer.videoPID)
        // and nothing after the first stream but the CRC
        #expect(map[18] != MPEGTSMuxer.streamTypeAAC)
    }

    /// With sound it declares two streams, and the length follows from the
    /// count rather than being written twice.
    @Test func withAudioTheMapDeclaresBothStreams() {
        let map: [UInt8] = Self.map(carryingAudio: true)
        #expect(map[3] == 0x17, "the two-stream PMT is not 23 bytes")
        #expect(map[13] == MPEGTSMuxer.streamTypeH264)
        let video: UInt16 = (UInt16(map[14] & 0x1F) << 8) | UInt16(map[15])
        #expect(video == MPEGTSMuxer.videoPID)
        #expect(map[18] == MPEGTSMuxer.streamTypeAAC)
        let audio: UInt16 = (UInt16(map[19] & 0x1F) << 8) | UInt16(map[20])
        #expect(audio == MPEGTSMuxer.audioPID)
        // The clock reference does NOT move: a program has one, and changing it
        // because a second stream appeared would restate the feed's timing.
        let pcrPID: UInt16 = (UInt16(map[9] & 0x1F) << 8) | UInt16(map[10])
        #expect(pcrPID == MPEGTSMuxer.videoPID)
    }

    /// **The checksum covers the section that was actually written**, in both
    /// shapes. A table whose CRC was computed over the old length is a table
    /// every receiver on set discards, and the picture goes with it — this is
    /// the failure mode of adding a stream to a PMT.
    @Test func bothShapesCarryTheChecksumOfTheirOwnSection() {
        for carryingAudio in [false, true] {
            let map: [UInt8] = Self.map(carryingAudio: carryingAudio)
            let sectionLength = Int(map[3]) + 3
            let body: [UInt8] = Array(map[1..<(1 + sectionLength - 4)])
            let written = UInt32(map[sectionLength - 3]) << 24
                | UInt32(map[sectionLength - 2]) << 16
                | UInt32(map[sectionLength - 1]) << 8
                | UInt32(map[sectionLength])
            #expect(written == MPEGTSMuxer.crc32(body),
                    "audio \(carryingAudio): the PMT checksum is stale")
        }
    }
}

/// **What the sound costs the wire**, which is why audio packets are held back
/// rather than padded out.
///
/// Every datagram is 1316 bytes whatever is in it. One AAC access unit is about
/// three transport packets, so padding each one to seven costs four null
/// packets every 21.3 ms — about 280 kbit/s, which is more than the audio
/// stream itself. So they wait for a whole datagram, and a picture flushes
/// whatever is left.
@Suite struct SRTAudioPaddingTests {
    @Test func soundAloneIsNeverPadded() {
        var muxer = AudioMuxFixtures.muxer()
        var datagrams: [Data] = []
        for index in 0..<30 {
            datagrams += muxer.datagrams(
                forAudio: AudioMuxFixtures.unit(bytes: 350,
                                                ticks: Int64(index) * 1920))
        }
        // Counted rather than collected: a failed `#expect` renders its
        // operands, and a list of 188-byte packets is pages of 255s.
        let nulls: Int = MPEGTSFixtures.packets(datagrams)
            .filter { MPEGTSFixtures.pid(of: $0) == MPEGTSMuxer.nullPID }.count
        #expect(nulls == 0, "\(nulls) null packets in a sound-only run")
        #expect(!datagrams.isEmpty, "no sound went out at all")
    }

    /// Never more than six packets are held, because seven is a datagram and a
    /// datagram leaves. That is the bound on how long a unit can wait.
    @Test func neverMoreThanADatagramIsHeld() {
        var muxer = AudioMuxFixtures.muxer()
        for index in 0..<50 {
            _ = muxer.datagrams(
                forAudio: AudioMuxFixtures.unit(bytes: 350,
                                                ticks: Int64(index) * 1920))
            #expect(muxer.heldPackets < MPEGTSMuxer.packetsPerDatagram,
                    "\(muxer.heldPackets) packets held after unit \(index)")
        }
    }

    /// **A picture flushes.** The feed replacing a cable is the picture, and it
    /// keeps the latency it had: nothing is left pending after a video unit.
    @Test func aPictureTakesEverythingPendingWithIt() {
        var muxer = AudioMuxFixtures.muxer()
        _ = muxer.datagrams(forAudio: AudioMuxFixtures.unit(bytes: 350))
        #expect(muxer.heldPackets > 0, "the sound was not held at all")
        _ = muxer.datagrams(for: MPEGTSFixtures.unit(bytes: 4_000, pts: 1920))
        #expect(muxer.heldPackets == 0, "a picture left sound pending")
    }

    /// …and the picture's own datagrams are unchanged by the carry buffer
    /// existing. With nothing pending, a video unit produces exactly what it
    /// produced before there was any sound.
    @Test func thePicturesDatagramsAreUnchangedWithNoSound() {
        var withCarry = MPEGTSMuxer()
        var plain = MPEGTSMuxer()
        for index in 0..<6 {
            let unit = MPEGTSFixtures.unit(bytes: 3_000 + index * 700,
                                           pts: Int64(index) * 3600,
                                           keyframe: index % 3 == 0)
            #expect(withCarry.datagrams(for: unit) == plain.datagrams(for: unit))
            #expect(withCarry.heldPackets == 0)
        }
        _ = plain
    }
}
