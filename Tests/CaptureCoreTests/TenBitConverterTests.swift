import CoreVideo
import Foundation
import Testing
@testable import CaptureCore

/// The 10-bit path had a shipped bug where record buffers carried r210 content
/// under a 2vuy label, so the format tags are asserted here alongside the
/// levels arithmetic and the multi-band split.
struct TenBitConverterTests {
    /// An r210 frame whose every pixel is `code` in all three components.
    private func makeR210(width: Int, height: Int,
                          code: (_ x: Int, _ y: Int) -> Int) -> CVPixelBuffer {
        var out: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            TenBitConverter.r210,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                            &out)
        let buffer = out!
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow)
                .assumingMemoryBound(to: UInt32.self)
            for x in 0..<width {
                let value = UInt32(code(x, y) & 0x3FF)
                row[x] = ((value << 20) | (value << 10) | value).bigEndian
            }
        }
        return buffer
    }

    private func bgraPixel(_ buffer: CVPixelBuffer, x: Int, y: Int) -> UInt32 {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!
        let row = base.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer))
            .assumingMemoryBound(to: UInt32.self)
        return row[x]
    }

    /// Red channel of an r210 buffer, back in wire code units.
    private func r210Red(_ buffer: CVPixelBuffer, x: Int, y: Int) -> Int {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!
        let row = base.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer))
            .assumingMemoryBound(to: UInt32.self)
        return Int((UInt32(bigEndian: row[x]) >> 20) & 0x3FF)
    }

    @Test func productsKeepTheirOwnPixelFormats() throws {
        let converter = TenBitConverter()
        let source = makeR210(width: 32, height: 4) { _, _ in 512 }
        let result = try #require(converter.convert(source))
        // the display product is 8-bit BGRA, the record product stays r210 —
        // mislabelling the record buffer is what shipped as a bug once
        #expect(CVPixelBufferGetPixelFormatType(result.display)
            == kCVPixelFormatType_32BGRA)
        #expect(CVPixelBufferGetPixelFormatType(result.record)
            == TenBitConverter.r210)
        #expect(CVPixelBufferGetWidth(result.record) == 32)
        #expect(CVPixelBufferGetHeight(result.record) == 4)
    }

    @Test func nonR210InputIsRejected() {
        let converter = TenBitConverter()
        var bgra: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA,
                            nil, &bgra)
        #expect(converter.convert(bgra!) == nil)
    }

    @Test func fullRangeSourcePassesCodesThroughToDisplay() throws {
        let converter = TenBitConverter()
        converter.setLimitedRange(false)
        // 940 in, no expansion: the display byte is just the top 8 bits
        let source = makeR210(width: 8, height: 2) { _, _ in 940 }
        let result = try #require(converter.convert(source))
        let pixel = bgraPixel(result.display, x: 0, y: 0)
        #expect(pixel & 0xFF == UInt32(940 >> 2))          // blue
        #expect((pixel >> 8) & 0xFF == UInt32(940 >> 2))   // green
        #expect((pixel >> 16) & 0xFF == UInt32(940 >> 2))  // red
        #expect(pixel >> 24 == 0xFF)                       // opaque alpha
    }

    /// Limited expands the NOMINAL pair: black 64 onto 0 and white 940 onto
    /// 1023, with the camera's excursions clipped against those ends. This is
    /// the picture the operator judges exposure on, so black has to be black;
    /// the codes outside the pair are kept where they are useful, in the file
    /// and on the scopes, and neither reads this buffer.
    @Test func limitedRangeSourceIsExpandedOnTheNominalPair() throws {
        let converter = TenBitConverter() // limited is the default
        let codes = [4, 64, 500, 940, 1019]
        let source = makeR210(width: codes.count, height: 2) { x, _ in codes[x] }
        let result = try #require(converter.convert(source))
        let shown = (0..<codes.count).map {
            Int(bgraPixel(result.display, x: $0, y: 0) & 0xFF)
        }
        #expect(shown == [0, 0, 127, 255, 255], "display bytes: \(shown)")
    }

    @Test func recordValuesLandInsideVideoToolboxsWindow() throws {
        let converter = TenBitConverter()
        converter.setLimitedRange(false)
        let source = makeR210(width: 4, height: 2) { x, _ in x == 0 ? 0 : 1023 }
        let result = try #require(converter.convert(source))
        // the ends of the wire map onto the 64-960 window VideoToolbox expands
        // back to 0-1023 inside the codec
        #expect(r210Red(result.record, x: 0, y: 0) == 64)
        #expect(r210Red(result.record, x: 1, y: 0) == 960)
    }

    /// The record buffer is the camera's wire codes, precompensated for the
    /// codec and for nothing else — so the levels mode, which is a decision
    /// about the MONITOR, cannot reach the deliverable. It used to: `precomp`
    /// was built from the expanded value, and a display window that clipped
    /// took those codes out of the file as well.
    @Test func theRecordBufferIsTheSameWhateverTheDisplayIsDoing() throws {
        let codes = [4, 64, 500, 940, 1019]
        var recorded: [[Int]] = []
        for levels in [InputLevels.limited, .full] {
            let converter = TenBitConverter()
            converter.setLevels(levels)
            let source = makeR210(width: codes.count, height: 2) { x, _ in codes[x] }
            let result = try #require(converter.convert(source))
            recorded.append((0..<codes.count).map {
                r210Red(result.record, x: $0, y: 0)
            })
        }
        #expect(recorded[0] == recorded[1],
                "the display mode changed the file: \(recorded)")
        #expect(recorded[0] == [68, 120, 502, 887, 956],
                "record codes: \(recorded[0])")
    }

    /// The precompensation only pays off if the codec's expansion brings the
    /// values back where they started — and what has to come back now is the
    /// WIRE code, footroom and headroom included, not an expanded value.
    @Test func precompensationRoundTripsToTheWireCodeWithinOneCode() throws {
        for levels in [InputLevels.limited, .full] {
            let converter = TenBitConverter()
            converter.setLevels(levels)
            let codes = [0, 1, 4, 64, 255, 512, 800, 940, 1019, 1022, 1023]
            let source = makeR210(width: codes.count, height: 2) { x, _ in codes[x] }
            let result = try #require(converter.convert(source))
            for (x, code) in codes.enumerated() {
                let recorded = r210Red(result.record, x: x, y: 0)
                // VideoToolbox reads r210 as video-range and expands 64-960 to 0-1023
                let decoded = Int((Double(recorded) - 64) * 1023 / 896 + 0.5)
                let detail = "recorded as \(recorded), decoded back as \(decoded)"
                #expect(abs(decoded - code) <= 1,
                        "\(levels): code \(code) \(detail)")
            }
        }
    }

    /// Rows are converted in parallel bands; a band-boundary mistake shows up as
    /// rows carrying another row's value, so every row gets its own code here.
    @Test func everyRowSurvivesTheParallelBandSplit() throws {
        let converter = TenBitConverter()
        converter.setLimitedRange(false)
        let height = 1080 // enough rows to split into the maximum number of bands
        let source = makeR210(width: 8, height: height) { _, y in (y * 7) % 1024 }
        let result = try #require(converter.convert(source))
        for y in 0..<height {
            let expected = (y * 7) % 1024
            #expect(r210Red(result.record, x: 0, y: y)
                == 64 + Int(Double(expected) * 896 / 1023 + 0.5),
                "row \(y) came back wrong")
            #expect(bgraPixel(result.display, x: 0, y: y) & 0xFF
                == UInt32(expected >> 2), "row \(y) display came back wrong")
        }
    }
}
