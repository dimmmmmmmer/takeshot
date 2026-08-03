import CoreVideo
import Foundation
import Testing

@testable import CaptureCore

/// The 12-bit split: one wire frame into a NOMINAL-mapped display buffer and a
/// record buffer carrying the wire codes.
///
/// The 10-bit suite next door (`TenBitConverterTests`, `LevelsExcursionTests`)
/// pins the same properties for 'r210', and the numbers here are deliberately
/// the same statements one bit depth up — studio swing at 12 bits is 256…3760,
/// which is the same fraction of the scale as 64…940 is at 10.
struct TwelveBitConverterTests {
    private func displayByte(_ buffer: CVPixelBuffer, x: Int, y: Int = 0) -> UInt32 {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!
        let row = base.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer))
            .assumingMemoryBound(to: UInt32.self)
        return row[x] & 0xFF // blue of BGRA; the fixtures are grey
    }

    /// One component of the 64RGBALE record buffer. 16-bit little-endian
    /// R, G, B, A — a native `UInt16` load on this host, which is why that
    /// format was chosen over the big-endian 'b64a'.
    private func recordComponent(_ buffer: CVPixelBuffer, x: Int, y: Int = 0,
                                 channel: Int = 0) -> Int {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!
        let row = base.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer))
            .assumingMemoryBound(to: UInt16.self)
        return Int(row[x * 4 + channel])
    }

    /// The five codes the whole levels question is about, at 12-bit scale.
    private static let codes = [
        R12BFixtures.footroom, R12BFixtures.nominalBlack, R12BFixtures.midGrey,
        R12BFixtures.nominalWhite, R12BFixtures.headroom,
    ]

    @Test func productsKeepTheirOwnPixelFormats() throws {
        let converter = TwelveBitConverter()
        let source = try R12BFixtures.makeGrey(width: 32, height: 4) { _, _ in 2048 }
        let result = try #require(converter.convert(source))
        #expect(CVPixelBufferGetPixelFormatType(result.display)
            == kCVPixelFormatType_32BGRA)
        // 16-bit RGBA, not 'r210': the 12-bit record path needs a container
        // that can hold twelve bits per component
        #expect(CVPixelBufferGetPixelFormatType(result.record)
            == kCVPixelFormatType_64RGBALE)
        #expect(CVPixelBufferGetWidth(result.record) == 32)
        #expect(CVPixelBufferGetHeight(result.record) == 4)
    }

    @Test func aNonR12BInputIsRejected() {
        let converter = TwelveBitConverter()
        var bgra: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA,
                            nil, &bgra)
        #expect(converter.convert(bgra!) == nil)
        // …and an 'r210' frame is not this converter's either, so a mislabelled
        // wire buffer is dropped rather than unpacked as 12-bit
        var r210: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, TenBitConverter.r210,
                            nil, &r210)
        #expect(converter.convert(r210!) == nil)
    }

    @Test func theConverterStatesItsRecordFormatAndFrameCost() {
        let twelve = TwelveBitConverter()
        #expect(twelve.wireFormat == R12BPacking.pixelFormat)
        #expect(twelve.recordPixelFormat == kCVPixelFormatType_64RGBALE)
        // 8 bytes a pixel against 'r210's 4 — the pre-roll ring is sized from
        // this, and getting it wrong is an out-of-memory at UHD
        #expect(twelve.recordBytesPerPixel == 8)
        let ten = TenBitConverter()
        #expect(ten.recordBytesPerPixel == 4)
    }

    @Test func fullRangeSourcePassesCodesThroughToDisplay() throws {
        let converter = TwelveBitConverter()
        converter.setLevels(.full)
        // 3760 in, no expansion: the display byte is just the top 8 bits
        let source = try R12BFixtures.makeGrey(width: 8, height: 2) { _, _ in 3760 }
        let result = try #require(converter.convert(source))
        #expect(displayByte(result.display, x: 0) == UInt32(3760 >> 4))
    }

    /// Limited expands the NOMINAL pair: black 256 onto 0 and white 3760 onto
    /// 4095, with the camera's excursions clipped against those ends. Same rule
    /// the 10-bit path applies, same reason — the operator judges exposure
    /// against a black that is black.
    @Test func limitedRangeSourceIsExpandedOnTheNominalPair() throws {
        let converter = TwelveBitConverter() // limited is the default
        let codes = Self.codes
        let source = try R12BFixtures.makeGrey(width: codes.count,
                                               height: 2) { x, _ in codes[x] }
        let result = try #require(converter.convert(source))
        let shown = (0..<codes.count).map { Int(displayByte(result.display, x: $0)) }
        // footroom and nominal black are both 0; the super-white and nominal
        // white are both 255 — the excursions clip, deliberately
        #expect(shown == [0, 0, 130, 255, 255], "display bytes: \(shown)")
    }

    /// The record buffer is the camera's wire codes and nothing else, so the
    /// levels mode — a decision about the MONITOR — cannot reach the
    /// deliverable. The 10-bit path had this bug once; the 12-bit one is built
    /// from the wire code by construction, and this is the test that says so.
    @Test func theRecordBufferIsTheSameWhateverTheDisplayIsDoing() throws {
        let codes = Self.codes
        var recorded: [[Int]] = []
        for levels in [InputLevels.limited, .full] {
            let converter = TwelveBitConverter()
            converter.setLevels(levels)
            let source = try R12BFixtures.makeGrey(width: codes.count,
                                                   height: 2) { x, _ in codes[x] }
            let result = try #require(converter.convert(source))
            recorded.append((0..<codes.count).map {
                recordComponent(result.record, x: $0)
            })
        }
        #expect(recorded[0] == recorded[1],
                "the display mode changed the file: \(recorded)")
        // the identity: the wire code in the top 12 bits of a 16-bit component.
        // No precompensation, because VideoToolbox reads this format as FULL
        // range — measured, see TwelveBitRecordTests.
        #expect(recorded[0] == codes.map { $0 << 4 },
                "record components: \(recorded[0])")
    }

    /// The record encoding is exactly invertible, which is what makes the file
    /// wire-EXACT rather than merely wire-referred: rounding the 16-bit value
    /// back down returns the code the camera sent, for every code.
    @Test func theRecordEncodingInvertsForEveryCode() throws {
        let converter = TwelveBitConverter()
        for code in 0...R12BPacking.maxCode {
            let stored = code << 4
            #expect((stored + 8) >> 4 == code, "code \(code) stored \(stored)")
        }
        // …and the buffer really carries that, at both ends of the range
        let ends = [0, R12BPacking.maxCode]
        let source = try R12BFixtures.makeGrey(width: 2, height: 2) { x, _ in ends[x] }
        let result = try #require(converter.convert(source))
        #expect(recordComponent(result.record, x: 0) == 0)
        #expect(recordComponent(result.record, x: 1) == 65520)
    }

    /// R, G and B must not be swapped on either product. A grey fixture cannot
    /// see that, so this one is deliberately not grey.
    @Test func theChannelsDoNotGetSwapped() throws {
        let converter = TwelveBitConverter()
        converter.setLevels(.full)
        let source = try R12BFixtures.makeR12B(width: 8, height: 2) { _, _ in
            R12BPacking.Pixel(r: 4000, g: 2000, b: 100)
        }
        let result = try #require(converter.convert(source))
        #expect(recordComponent(result.record, x: 3, channel: 0) == 4000 << 4)
        #expect(recordComponent(result.record, x: 3, channel: 1) == 2000 << 4)
        #expect(recordComponent(result.record, x: 3, channel: 2) == 100 << 4)
        // opaque alpha: ProRes 4444 carries one, and a transparent take is not
        // a deliverable
        #expect(recordComponent(result.record, x: 3, channel: 3) == 0xFFFF)
        // display is BGRA, so the low byte is blue and the high-but-one is red
        CVPixelBufferLockBaseAddress(result.display, .readOnly)
        let base = CVPixelBufferGetBaseAddress(result.display)!
            .assumingMemoryBound(to: UInt32.self)
        let pixel = base[3]
        CVPixelBufferUnlockBaseAddress(result.display, .readOnly)
        #expect(pixel & 0xFF == UInt32(100 >> 4))
        #expect((pixel >> 8) & 0xFF == UInt32(2000 >> 4))
        #expect((pixel >> 16) & 0xFF == UInt32(4000 >> 4))
        #expect(pixel >> 24 == 0xFF)
    }

    /// Rows are converted in parallel bands, and a band-boundary mistake shows
    /// up as rows carrying another row's value — so every row gets its own code.
    /// Also the case where the frame is many blocks wide.
    @Test func everyRowSurvivesTheParallelBandSplit() throws {
        let converter = TwelveBitConverter()
        converter.setLevels(.full)
        let height = 1080 // enough rows to reach the maximum band count
        let source = try R12BFixtures.makeGrey(width: 24, height: height) { _, y in
            (y * 3 + 7) & 0xFFF
        }
        let result = try #require(converter.convert(source))
        for y in 0..<height {
            let expected = (y * 3 + 7) & 0xFFF
            #expect(recordComponent(result.record, x: 17, y: y) == expected << 4,
                    "row \(y) record came back wrong")
            #expect(displayByte(result.display, x: 17, y: y)
                == UInt32(expected >> 4), "row \(y) display came back wrong")
        }
    }

    /// A width that is not a multiple of eight leaves a partial trailing block.
    /// Every pixel inside the frame still has to be right.
    @Test func aPartialTrailingBlockIsStillExact() throws {
        let converter = TwelveBitConverter()
        converter.setLevels(.full)
        let width = 13 // one full block plus five pixels
        let source = try R12BFixtures.makeGrey(width: width, height: 2) { x, _ in
            (x + 1) * 300
        }
        let result = try #require(converter.convert(source))
        for x in 0..<width {
            #expect(recordComponent(result.record, x: x) == ((x + 1) * 300) << 4,
                    "pixel \(x) of a partial block came back wrong")
        }
    }
}

/// The display half of the split, which is shared policy rather than either
/// converter's own code (`WireDisplayTable`).
///
/// This is the architecture claim in numbers: 10-bit and 12-bit sources are
/// expanded by ONE table builder, so a 12-bit black lands exactly where a
/// 10-bit black does and the two paths cannot drift into showing different
/// pictures of the same scene.
struct WireDisplayTableTests {
    @Test func theNominalPairLandsOnTheEndsAtEveryDepth() {
        for bits in [8, 10, 12] {
            let table = WireDisplayTable.expand(levels: .limited, bits: bits)
            let window = InputLevels.limited.wireWindow(bits: bits)
            let top = (1 << bits) - 1
            #expect(table.count == 1 << bits)
            #expect(table[window.black] == 0, "\(bits)-bit black")
            #expect(table[top] == UInt16(top), "\(bits)-bit above white clips")
            #expect(table[window.white] == UInt16(top), "\(bits)-bit white")
            // below nominal black clips to black rather than wrapping
            #expect(table[0] == 0, "\(bits)-bit code 0")
        }
    }

    @Test func studioSwingIsTheSameFractionOfTheScaleAtEveryDepth() {
        #expect(InputLevels.limited.wireWindow(bits: 8) == (16, 235))
        #expect(InputLevels.limited.wireWindow(bits: 10) == (64, 940))
        #expect(InputLevels.limited.wireWindow(bits: 12) == (256, 3760))
        #expect(InputLevels.full.wireWindow(bits: 12) == (0, 4095))
        // the retired spelling still resolves, and the 8-bit accessor is now
        // just this rule at another depth
        #expect(InputLevels.limited.eightBitWindow == (16, 235))
        #expect(InputLevels.full.eightBitWindow == (0, 255))
    }

    /// The same scene at 10 and 12 bits reaches the monitor as the same
    /// picture. Compared on the 8 bits the display buffer actually holds, which
    /// is where any drift would be visible.
    @Test func tenAndTwelveBitAgreeOnTheDisplayedPicture() {
        let ten = WireDisplayTable.expand(levels: .limited, bits: 10)
        let twelve = WireDisplayTable.expand(levels: .limited, bits: 12)
        for tenBitCode in 0..<1024 {
            let fromTen = Int(ten[tenBitCode]) >> 2          // 10-bit → 8-bit
            let fromTwelve = Int(twelve[tenBitCode << 2]) >> 4 // 12-bit → 8-bit
            #expect(abs(fromTen - fromTwelve) <= 1,
                    "code \(tenBitCode): 10-bit \(fromTen), 12-bit \(fromTwelve)")
        }
    }

    @Test func fullRangeIsTheIdentity() {
        let table = WireDisplayTable.expand(levels: .full, bits: 12)
        for code in [0, 1, 256, 2048, 3760, 4095] {
            #expect(table[code] == UInt16(code))
        }
    }
}
