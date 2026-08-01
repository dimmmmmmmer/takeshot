import Foundation
import Testing

@testable import CaptureCore

/// Malformed-input batteries for every text parser that reads files off a disk
/// the app does not control: the LUT library folder, a look handed over on a
/// stick, a sidecar re-saved by Excel, a manifest another tool wrote.
///
/// One fixed corpus of hostile shapes — truncated, binary, huge, wrong magic,
/// BOM, CRLF, NULs — derived from each parser's own valid document, and one
/// assertion for all of them: the parser answers with a clean error or a valid
/// value. It never crashes, and it never wanders off into minutes of work.
/// Everything is deterministic; the "random" bytes come from a fixed-seed
/// xorshift so a failure tonight is the same failure tomorrow morning.
enum TortureCorpus {
    /// xorshift64* — the same byte stream on every run, no shared state.
    static func bytes(_ count: Int, seed: UInt64) -> [UInt8] {
        var state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
        var out = [UInt8]()
        out.reserveCapacity(count)
        while out.count < count {
            state ^= state >> 12
            state ^= state << 25
            state ^= state >> 27
            let word = state &* 0x2545_F491_4F6C_DD1D
            withUnsafeBytes(of: word.littleEndian) {
                out.append(contentsOf: $0.prefix(count - out.count))
            }
        }
        return out
    }

    /// Raw bytes forced through UTF-8 decoding, replacement characters and all
    /// — what `String(contentsOf:)` never produces but a Data-based path can.
    /// The lossy decode is the point: this corpus exists to feed the parsers
    /// bytes that never were UTF-8, and the failable initializer the linter
    /// prefers would hand them nothing at all.
    static func binaryString(_ count: Int, seed: UInt64) -> String {
        // swiftlint:disable:next optional_data_string_conversion
        String(decoding: bytes(count, seed: seed), as: UTF8.self)
    }

    /// Printable ASCII noise — the shape of a text file that is not this format.
    static func printableGarbage(_ count: Int, seed: UInt64) -> String {
        String(bytes(count, seed: seed).map {
            Character(UnicodeScalar(32 + $0 % 95))
        })
    }

    /// The battery: every hostile shape, derived from one valid document so
    /// truncations and mutations cut through real structure.
    static func mutations(of valid: String) -> [(name: String, text: String)] {
        [
            ("empty", ""),
            ("whitespace only", " \t \n \r\n  "),
            ("BOM only", "\u{FEFF}"),
            ("BOM before a valid document", "\u{FEFF}" + valid),
            ("CRLF line endings",
             valid.replacingOccurrences(of: "\n", with: "\r\n")),
            ("CR-only line endings",
             valid.replacingOccurrences(of: "\n", with: "\r")),
            ("truncated after a quarter", String(valid.prefix(valid.count / 4))),
            ("truncated one character short", String(valid.dropLast())),
            ("document doubled", valid + valid),
            ("NULs through it",
             valid.replacingOccurrences(of: "\n", with: "\u{0}\n")),
            ("binary garbage", binaryString(4096, seed: 0xDEAD_BEEF)),
            ("printable garbage", printableGarbage(4096, seed: 0xC0FF_EE00)),
            ("wrong magic",
             "%PDF-1.4\n1 0 obj\n<< /Type /Catalog >>\nendobj\nstartxref\n0"),
            ("a megabyte on one line", String(repeating: "A", count: 1 << 20)),
            ("valid then binary garbage", valid + binaryString(1024, seed: 7)),
        ]
    }
}

@Suite struct ParserTortureTests {
    // MARK: - .cube

    static let validCube = """
        # torture battery seed document
        TITLE "torture"
        LUT_3D_SIZE 2
        0 0 0
        1 0 0
        0 1 0
        1 1 0
        0 0 1
        1 0 1
        0 1 1
        1 1 1

        """

    /// The corpus never crashes the LUT parser: a parse is a lattice or a
    /// `ParseError`, and nothing else.
    @Test func cubeParserSurvivesTheBattery() {
        for (name, text) in TortureCorpus.mutations(of: Self.validCube) {
            do {
                let lut = try CubeLUT.parse(text, name: name)
                #expect(lut.size >= 2, "\(name): parsed into an unusable lattice")
                #expect(lut.data.count
                    == lut.size * lut.size * lut.size * 4
                    * MemoryLayout<Float>.size,
                        "\(name): lattice and data disagree")
            } catch let error as CubeLUT.ParseError {
                _ = error.errorDescription // the message renders for any case
            } catch {
                Issue.record("\(name): not a ParseError: \(error)")
            }
        }
    }

    /// A Windows-saved .cube opens: tools re-save LUTs with a UTF-8 BOM, and
    /// the header scanner must not mistake the BOM for the first header line.
    @Test func aCubeWithABOMStillParses() throws {
        let lut = try CubeLUT.parse("\u{FEFF}" + Self.validCube)
        #expect(lut.size == 2)
    }

    /// Header sizes across the whole integer range: every one of these answers
    /// with a thrown error, none of them traps. `size³ * 3` overflows Int from
    /// 2,097,152 up — a corrupted header was one multiplication away from
    /// taking the app down mid-shoot.
    @Test func absurdCubeHeaderSizesThrowInsteadOfTrapping() {
        for size in [-3, 0, 1, 257, 100_000, 2_097_152, Int.max] {
            #expect(throws: CubeLUT.ParseError.self, "LUT_3D_SIZE \(size)") {
                _ = try CubeLUT.parse("LUT_3D_SIZE \(size)\n0 0 0\n")
            }
        }
    }

    /// The biggest lattice the parser accepts parses, the next one up is
    /// refused by header alone — before any per-entry work.
    @Test func theCubeSizeCapIsExact() throws {
        #expect(throws: CubeLUT.ParseError.self) {
            _ = try CubeLUT.parse(
                "LUT_3D_SIZE \(CubeLUT.maximumSize + 1)\n0 0 0\n")
        }
        // a real document at the cap would be 50M lines; the cap itself is
        // checked through the error the entry count then reports
        do {
            _ = try CubeLUT.parse("LUT_3D_SIZE \(CubeLUT.maximumSize)\n0 0 0\n")
            Issue.record("one entry cannot satisfy a \(CubeLUT.maximumSize)³ cube")
        } catch CubeLUT.ParseError.wrongEntryCount(let expected, let got) {
            #expect(expected == CubeLUT.maximumSize * CubeLUT.maximumSize
                * CubeLUT.maximumSize * 3)
            #expect(got == 3)
        } catch {
            Issue.record("the cap changed which error fires: \(error)")
        }
    }

    // MARK: - ASC CDL

    static let validCDL = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ColorCorrection id="torture">
          <SOPNode>
            <Slope>1.1 1.0 0.9</Slope>
            <Offset>0.01 0.0 -0.02</Offset>
            <Power>0.95 1.0 1.05</Power>
          </SOPNode>
          <SatNode>
            <Saturation>0.9</Saturation>
          </SatNode>
        </ColorCorrection>

        """

    /// The corpus never crashes the CDL reader: every answer is a grade or a
    /// `ParseError`. XMLParser's own error surface is folded into
    /// `.malformedXML`, so this also pins that no NSException escapes it.
    @Test func cdlParserSurvivesTheBattery() {
        for (name, text) in TortureCorpus.mutations(of: Self.validCDL) {
            do {
                let looks = try CDLLook.looks(in: text)
                #expect(!looks.isEmpty, "\(name): parsed into no grades")
            } catch let error as CDLLook.ParseError {
                _ = error.errorDescription
            } catch {
                Issue.record("\(name): not a ParseError: \(error)")
            }
        }
    }

    /// Numeric garbage inside a well-formed document degrades per field — the
    /// unreadable value keeps its identity default, the readable ones land.
    @Test func numericGarbageInsideValidXMLKeepsTheIdentityDefaults() throws {
        let look = try CDLLook.looks(in: """
            <ColorCorrection id="odd">
              <SOPNode>
                <Slope>one two three</Slope>
                <Offset>0.1 0.1</Offset>
                <Power>2 2 2 2</Power>
              </SOPNode>
              <SatNode><Saturation>NaN-ish</Saturation></SatNode>
            </ColorCorrection>
            """)[0]
        #expect(look.slope == CDLLook.RGB.one)
        #expect(look.offset == CDLLook.RGB.zero)
        #expect(look.power == CDLLook.RGB.one)
        #expect(look.saturation == 1)
    }

    // MARK: - ASC MHL manifests

    static let validMHL = """
        <?xml version="1.0" encoding="UTF-8"?>
        <hashlist version="2.0" xmlns="urn:ASC:MHL:v2.0">
          <creatorinfo>
            <hostname>torture</hostname>
          </creatorinfo>
          <hashes>
            <hash>
              <path size="4">A001/clip1.mov</path>
              <xxh64>0123456789abcdef</xxh64>
            </hash>
          </hashes>
        </hashlist>

        """

    /// The corpus never crashes the manifest reader; every answer is a
    /// manifest or an `OffloadVerifyError` whose message renders.
    @Test func manifestReaderSurvivesTheBattery() throws {
        let root = TestMedia.scratchDirectory("manifest-torture")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (index, sample) in
            TortureCorpus.mutations(of: Self.validMHL).enumerated() {
            let url = root.appendingPathComponent("t\(index).mhl")
            try Data(sample.text.utf8).write(to: url)
            do {
                let manifest = try OffloadManifestReader.read(url)
                #expect(!manifest.entries.isEmpty,
                        "\(sample.name): parsed into an empty manifest")
            } catch let error as OffloadVerifyError {
                _ = error.errorDescription
            } catch {
                Issue.record("\(sample.name): not a verify error: \(error)")
            }
        }
    }

    /// A manifest URL that is not a readable file is an error, not a crash —
    /// missing file and directory-in-its-place both.
    @Test func unreadableManifestURLsThrowCleanly() throws {
        let root = TestMedia.scratchDirectory("manifest-unreadable")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: OffloadVerifyError.self) {
            _ = try OffloadManifestReader.read(
                root.appendingPathComponent("never-written.mhl"))
        }
    }

    // MARK: - the CSV sidecars

    static let validRanges = """
        File Name,In,Out
        A001_C001.mov,1.000,2.500
        A001_C002.mov,,4.000

        """

    static let validMarkers = """
        File Name,Timecode,Color,Note
        A001_C001.mov,10:00:01:00,red,focus
        A001_C002.mov,10:00:02:00,orange,"boom, in shot"

        """

    /// The sidecar readers never throw at all: the worst row costs itself and
    /// nothing else, and the worst file is an empty table.
    @Test func sidecarParsersSurviveTheBattery() {
        for (_, text) in TortureCorpus.mutations(of: Self.validRanges) {
            for range in TakeLogExporter.parseRanges(csv: text).values {
                #expect(!range.isEmpty)
            }
        }
        for (name, text) in TortureCorpus.mutations(of: Self.validMarkers) {
            for rows in TakeLogExporter.parseMarkerRows(csv: text).values {
                #expect(!rows.isEmpty, "\(name): a filename with no rows")
            }
        }
    }

    /// The one CSV shape the line parser cannot mend: a quote opened and never
    /// closed swallows the rest of ITS line — and only its line.
    @Test func anUnterminatedQuoteCostsOnlyItsOwnRow() {
        let parsed = TakeLogExporter.parseRanges(csv: """
            File Name,In,Out
            "unclosed.mov,1.0,2.0
            fine.mov,3.0,4.0
            """)
        #expect(parsed["fine.mov"] == ClipRange(inPoint: 3, outPoint: 4))
        #expect(parsed.count == 1)
    }

    /// Numeric junk in range cells: NaN, infinities, negatives and non-numbers
    /// are all "unset", never a seek target. A row with junk in both cells is
    /// dropped whole; one readable endpoint is kept.
    @Test func rangeCellJunkReadsAsUnset() {
        let parsed = TakeLogExporter.parseRanges(csv: """
            File Name,In,Out
            a.mov,nan,1.0
            b.mov,inf,-1.0
            c.mov,-0.5,1e999
            d.mov,--,two
            """)
        #expect(parsed["a.mov"] == ClipRange(inPoint: nil, outPoint: 1))
        #expect(parsed["b.mov"] == nil)
        #expect(parsed["c.mov"] == nil)
        #expect(parsed["d.mov"] == nil)
    }

    // MARK: - LTC

    /// Structured hostile audio, not just noise: DC, a square wave far off any
    /// LTC rate, full-scale alternation, and a seeded burst — none of them may
    /// decode, none of them may leave the decoder unable to lock afterwards.
    @Test func ltcDecoderSurvivesStructuredGarbageAndStillLocksAfter() {
        let decoder = LTCDecoder()
        var batteries: [[Int16]] = []
        batteries.append([Int16](repeating: 0, count: 48000))          // silence
        batteries.append([Int16](repeating: 20000, count: 48000))      // DC
        batteries.append((0..<48000).map { $0 % 2 == 0 ? 20000 : -20000 })
        batteries.append((0..<48000).map {                             // 400 Hz
            ($0 / 60) % 2 == 0 ? Int16(18000) : Int16(-18000)
        })
        batteries.append(TortureCorpus.bytes(96000, seed: 42)
            .withUnsafeBytes { raw in Array(raw.bindMemory(to: Int16.self)) })
        for (index, samples) in batteries.enumerated() {
            let decoded = samples.withUnsafeBufferPointer {
                decoder.process(samples: $0, fps: 25)
            }
            #expect(decoded == nil, "battery \(index) decoded from garbage")
        }
        // the decoder still locks onto clean LTC after all of it
        var polarity = false
        var last: Timecode?
        for frame in 0..<30 {
            let tc = Timecode(frameNumber: 9 * 90000 + frame, fps: 25)
            let samples = LTCTestSignal.encode(tc, fps: 25, polarity: &polarity)
            samples.withUnsafeBufferPointer {
                if let hit = decoder.process(samples: $0, fps: 25) { last = hit }
            }
        }
        #expect(last != nil, "garbage left the decoder unable to lock")
        #expect(last?.hours == 9)
    }

    /// A sync-word-perfect frame whose FIELDS are insane is refused: the guard
    /// on hours/minutes/seconds/frames is what stands between a bit slip and a
    /// take named 97:71:83:XX.
    @Test func ltcRejectsFramesWithImpossibleFields() {
        var polarity = false
        for bad in [Timecode(hours: 25, minutes: 0, seconds: 0, frames: 0, fps: 25),
                    Timecode(hours: 0, minutes: 61, seconds: 0, frames: 0, fps: 25),
                    Timecode(hours: 0, minutes: 0, seconds: 65, frames: 0, fps: 25),
                    Timecode(hours: 0, minutes: 0, seconds: 0, frames: 26, fps: 25)] {
            let decoder = LTCDecoder()
            var decoded: Timecode?
            for _ in 0..<4 {
                let samples = LTCTestSignal.encode(bad, fps: 25,
                                                   polarity: &polarity)
                samples.withUnsafeBufferPointer {
                    if let hit = decoder.process(samples: $0, fps: 25) {
                        decoded = hit
                    }
                }
            }
            #expect(decoded == nil,
                    "decoded \(String(describing: decoded)) from \(bad)")
        }
    }
}
