import Foundation
import Testing

@testable import CaptureCore

/// **What a sound recordist's file says about itself.**
///
/// The dailies can line sound up with picture only if something can answer
/// "when was this recorded" for a WAV, and the only thing that does is the
/// `bext` chunk. Every case here is a way that answer goes wrong quietly: a
/// 64-bit sample count read as 32, a chunk whose odd length desynchronises the
/// walk, a file with no `bext` at all reading as midnight.
@Suite struct BroadcastWaveReaderTests {
    /// A synthesized Broadcast Wave. Built byte by byte because the point is
    /// the BYTES: an `AVAudioFile` would write whatever chunks it likes and
    /// this reader's whole job is to survive what recorders actually write.
    struct WaveBuilder {
        var sampleRate: UInt32 = 48_000
        var channels: UInt16 = 2
        var bitsPerSample: UInt16 = 24
        /// Samples since midnight — what `bext` calls TimeReference.
        var timeReference: UInt64?
        var iXML: String?
        var frames = 48_000
        /// An extra chunk of ODD length, written before `bext`, to walk over.
        var oddChunkBefore = false

        func data() -> Data {
            var chunks = Data()
            chunks += Self.chunk("fmt ", Self.formatPayload(
                channels: channels, sampleRate: sampleRate,
                bitsPerSample: bitsPerSample))
            if oddChunkBefore {
                chunks += Self.chunk("junk", Data([0x01, 0x02, 0x03]))
            }
            if let timeReference {
                chunks += Self.chunk("bext", Self.bextPayload(timeReference))
            }
            if let iXML {
                chunks += Self.chunk("iXML", Data(iXML.utf8))
            }
            let bytesPerFrame = Int(channels) * Int(bitsPerSample) / 8
            chunks += Self.chunk(
                "data", Data(repeating: 0, count: frames * bytesPerFrame))

            var file = Data("RIFF".utf8)
            file += Self.uint32(UInt32(4 + chunks.count))
            file += Data("WAVE".utf8)
            file += chunks
            return file
        }

        static func chunk(_ id: String, _ payload: Data) -> Data {
            var out = Data(id.utf8)
            out += uint32(UInt32(payload.count))
            out += payload
            // the pad byte a reader has to skip and no size counts
            if payload.count % 2 == 1 { out += Data([0]) }
            return out
        }

        static func formatPayload(channels: UInt16, sampleRate: UInt32,
                                  bitsPerSample: UInt16) -> Data {
            var out = Data()
            out += uint16(1)               // PCM
            out += uint16(channels)
            out += uint32(sampleRate)
            let blockAlign = UInt16(Int(channels) * Int(bitsPerSample) / 8)
            out += uint32(sampleRate * UInt32(blockAlign))
            out += uint16(blockAlign)
            out += uint16(bitsPerSample)
            return out
        }

        static func bextPayload(_ timeReference: UInt64) -> Data {
            var out = Data(repeating: 0, count: 338)
            out += uint32(UInt32(timeReference & 0xFFFF_FFFF))
            out += uint32(UInt32(timeReference >> 32))
            out += Data(repeating: 0, count: 602 - 346) // the rest of bext
            return out
        }

        static func uint16(_ value: UInt16) -> Data {
            withUnsafeBytes(of: value.littleEndian) { Data($0) }
        }

        static func uint32(_ value: UInt32) -> Data {
            withUnsafeBytes(of: value.littleEndian) { Data($0) }
        }
    }

    private func write(_ builder: WaveBuilder, named name: String) throws -> URL {
        let folder = TestMedia.scratchDirectory("BWFTests")
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try builder.data().write(to: url)
        return url
    }

    /// The plain case: rate, channels, duration and the start.
    @Test func aBroadcastWaveReadsItsFormatAndItsStart() throws {
        // 10:00:00:00 at 48 kHz is 36 000 s × 48 000.
        let start = UInt64(36_000 * 48_000)
        let url = try write(WaveBuilder(timeReference: start, frames: 96_000),
                            named: "plain.wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let facts = try BroadcastWaveReader.read(url)

        #expect(facts.sampleRate == 48_000)
        #expect(facts.channelCount == 2)
        #expect(facts.duration == 2, "the file is \(facts.duration)s, not 2")
        let seconds = try #require(facts.startSecondsSinceMidnight)
        #expect(seconds == 36_000, "the start reads \(seconds)s, not 10:00:00")
    }

    /// **TimeReference is 64 bits, and the high word is not decoration.**
    ///
    /// Read as 32 bits it is right up to about 24.8 hours at 48 kHz and wrong
    /// from 12.4 hours at 96 kHz — a rate features shoot at. The low word wraps
    /// in the middle of a night shoot and the file lands a day away from its
    /// picture, which is a sound department's worst afternoon.
    @Test func theStartUsesBothWordsOfTheSampleCount() throws {
        // 13:00:00 at 96 kHz: 46 800 s × 96 000 = 4 492 800 000, past 2^32.
        let start = UInt64(46_800) * 96_000
        #expect(start > UInt64(UInt32.max), "the fixture is not past 32 bits")
        let url = try write(
            WaveBuilder(sampleRate: 96_000, timeReference: start,
                        frames: 96_000), named: "long.wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let facts = try BroadcastWaveReader.read(url)

        let seconds = try #require(facts.startSecondsSinceMidnight)
        #expect(abs(seconds - 46_800) < 0.001, """
            the start reads \(seconds)s — 13:00 came back as \
            \(seconds / 3600)h, which is the low word alone
            """)
    }

    /// An odd-length chunk is padded, and the pad byte is not in the size. A
    /// reader that does not round up walks one byte out of step from there on
    /// and never finds `bext` — the file silently becomes unmatchable.
    @Test func anOddSizedChunkDoesNotDesynchroniseTheWalk() throws {
        let url = try write(
            WaveBuilder(timeReference: UInt64(3_600 * 48_000),
                        oddChunkBefore: true), named: "odd.wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let facts = try BroadcastWaveReader.read(url)
        #expect(facts.startSecondsSinceMidnight == 3_600, """
            the start is \(String(describing: facts.startSecondsSinceMidnight)) \
            — the walk lost its place on the odd chunk
            """)
    }

    /// No `bext` is not midnight. A file with no timecode matches nothing, and
    /// saying so is the difference between "the sound folder is wrong" and
    /// "every take lines up with 00:00:00".
    @Test func aFileWithNoTimecodeSaysSoRatherThanSayingMidnight() throws {
        let url = try write(WaveBuilder(), named: "notc.wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let facts = try BroadcastWaveReader.read(url)
        #expect(facts.startSecondsSinceMidnight == nil,
                "a file with no bext reported a start")
        #expect(facts.sampleRate == 48_000, "the rest of it was lost with it")
    }

    /// Track names come from the index the file STATES, not from the order the
    /// tracks are written in: a boom listed third but indexed 1 is channel 1.
    @Test func trackNamesAreKeyedByTheIndexTheFileStates() throws {
        let iXML = """
            <?xml version="1.0" encoding="UTF-8"?><BWFXML><SCENE>12A</SCENE>\
            <TAKE>3</TAKE><TRACK_LIST>\
            <TRACK><CHANNEL_INDEX>2</CHANNEL_INDEX><NAME>Lav</NAME></TRACK>\
            <TRACK><CHANNEL_INDEX>1</CHANNEL_INDEX><NAME>Boom</NAME></TRACK>\
            </TRACK_LIST></BWFXML>
            """
        let url = try write(
            WaveBuilder(timeReference: UInt64(48_000), iXML: iXML),
            named: "named.wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let facts = try BroadcastWaveReader.read(url)

        #expect(facts.trackNames[1] == "Boom", """
            channel 1 is \(String(describing: facts.trackNames[1])) — the names \
            were taken in document order
            """)
        #expect(facts.trackNames[2] == "Lav")
        #expect(facts.scene == "12A")
        #expect(facts.take == "3")
    }

    /// Something that is not a WAVE throws rather than answering with an empty
    /// fact: a default-constructed one matches nothing or everything, silently.
    @Test func anythingThatIsNotAWaveIsRefused() throws {
        let folder = TestMedia.scratchDirectory("BWFTests")
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("notes.txt")
        try Data("this is not a wave".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: BroadcastWaveReader.Failure.notAWave(url)) {
            try BroadcastWaveReader.read(url)
        }
    }
}
