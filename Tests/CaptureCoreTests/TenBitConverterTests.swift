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

    @Test func limitedRangeSourceExpandsBlackAndWhiteToTheFullScale() throws {
        let converter = TenBitConverter() // limited is the default
        // 64 is limited-range black, 940 is limited-range white
        let source = makeR210(width: 4, height: 2) { x, _ in x == 0 ? 64 : 940 }
        let result = try #require(converter.convert(source))
        #expect(bgraPixel(result.display, x: 0, y: 0) & 0xFF == 0)
        #expect(bgraPixel(result.display, x: 1, y: 0) & 0xFF == 255)
    }

    @Test func recordValuesLandInsideVideoToolboxsWindow() throws {
        let converter = TenBitConverter()
        converter.setLimitedRange(false)
        let source = makeR210(width: 4, height: 2) { x, _ in x == 0 ? 0 : 1023 }
        let result = try #require(converter.convert(source))
        // full-scale black and white map onto the 64-960 window VideoToolbox
        // expands back to 0-1023 inside the codec
        #expect(r210Red(result.record, x: 0, y: 0) == 64)
        #expect(r210Red(result.record, x: 1, y: 0) == 960)
    }

    /// The precompensation only pays off if the codec's expansion brings the
    /// values back where they started — the documented claim is +-1 in 10-bit units.
    @Test func precompensationRoundTripsWithinOneCode() throws {
        let converter = TenBitConverter()
        converter.setLimitedRange(false)
        let codes = [0, 1, 64, 255, 512, 800, 1022, 1023]
        let source = makeR210(width: codes.count, height: 2) { x, _ in codes[x] }
        let result = try #require(converter.convert(source))
        for (x, code) in codes.enumerated() {
            let recorded = r210Red(result.record, x: x, y: 0)
            // VideoToolbox reads r210 as video-range and expands 64-960 to 0-1023
            let decoded = Int((Double(recorded) - 64) * 1023 / 896 + 0.5)
            #expect(abs(decoded - code) <= 1,
                    "code \(code) recorded as \(recorded), decoded back as \(decoded)")
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
