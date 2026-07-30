import CoreVideo
import Foundation
import Testing

@testable import CaptureCore

/// Guards the scope analyzer's source readers after the three per-format passes
/// became one grid walk over a shared pixel reader: 420v had no coverage at all
/// (it is the playback/preview format), and both YUV readers now go through one
/// video-range conversion, so a mistake in it would move every trace on both.
struct CoreScopeReaderTests {
    /// Biplanar 4:2:0 video range: a luma plane and an interleaved CbCr plane
    /// at half resolution.
    private func make420v(width: Int = 320, height: Int = 180,
                          luma: UInt8, cb: UInt8 = 128,
                          cr: UInt8 = 128) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                            &pb)
        let buffer = try #require(pb)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let yBase = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 0))
            .assumingMemoryBound(to: UInt8.self)
        let yRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for y in 0..<height {
            memset(yBase + y * yRow, Int32(luma), width)
        }
        let cBase = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 1))
            .assumingMemoryBound(to: UInt8.self)
        let cRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        for y in 0..<(height / 2) {
            let row = cBase + y * cRow
            for pair in 0..<(width / 2) {
                row[pair * 2] = cb
                row[pair * 2 + 1] = cr
            }
        }
        return buffer
    }

    @Test func analyzes420vLumaOnTheSameScaleAs2vuy() throws {
        let data = try #require(ScopeAnalyzer.analyze(try make420v(luma: 180)))
        // video-range 180 → (180-16)*298>>8 = 190, exactly as the 2vuy path
        #expect(data.histY.firstIndex(of: data.histY.max()!) == 190)
        // neutral chroma → R≈G≈B
        let rPeak = try #require(data.histR.firstIndex(of: data.histR.max()!))
        let gPeak = try #require(data.histG.firstIndex(of: data.histG.max()!))
        let bPeak = try #require(data.histB.firstIndex(of: data.histB.max()!))
        #expect(abs(rPeak - gPeak) <= 2)
        #expect(abs(gPeak - bPeak) <= 2)
    }

    /// Video-range black and white land on the full-range ends: the conversion
    /// expands 16-235, and a 420v frame is where washed blacks would show up.
    @Test func analyzes420vRangeEnds() throws {
        let black = try #require(ScopeAnalyzer.analyze(try make420v(luma: 16)))
        #expect(black.histY.firstIndex(of: black.histY.max()!) == 0)
        let white = try #require(ScopeAnalyzer.analyze(try make420v(luma: 235)))
        let whitePeak = try #require(white.histY.firstIndex(of: white.histY.max()!))
        #expect(whitePeak >= 254)
    }

    /// A neutral frame has no chroma, so the vectorscope density belongs in the
    /// center cell — the one map that is not blurred before it is scaled.
    @Test func neutralFrameLeavesTheVectorscopeAtItsCenter() throws {
        let data = try #require(ScopeAnalyzer.analyze(try make420v(luma: 128)))
        let size = ScopeData.vectorSize
        let peak = try #require(data.vector.firstIndex(of: data.vector.max()!))
        #expect(abs(peak % size - size / 2) <= 1)
        #expect(abs(peak / size - size / 2) <= 1)
    }
}
