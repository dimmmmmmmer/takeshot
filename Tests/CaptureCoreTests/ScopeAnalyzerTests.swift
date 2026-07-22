import CoreVideo
import Foundation
import Testing
@testable import CaptureCore

struct ScopeAnalyzerTests {
    private func makeBGRA(width: Int = 320, height: Int = 180,
                          b: UInt8, g: UInt8, r: UInt8) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                            &pb)
        let buffer = pb!
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                let p = base + y * rowBytes + x * 4
                p[0] = b; p[1] = g; p[2] = r; p[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    @Test func solidGrayPeaksInMiddle() throws {
        let data = try #require(ScopeAnalyzer.analyze(
            makeBGRA(b: 128, g: 128, r: 128)))
        // all histogram energy in bin 128 (luma of equal RGB = the value itself)
        #expect(data.histY.firstIndex(of: data.histY.max()!) == 128)
        #expect(data.histR.firstIndex(of: data.histR.max()!) == 128)
        // the waveform trace sits on a single luma row: exactly one non-empty row
        let size = ScopeData.size
        let nonEmptyRows = (0..<size).filter { row in
            (0..<size).contains { data.waveform[row * size + $0] > 0 }
        }
        #expect(nonEmptyRows.count == 1)
        // 128/255 luma → the middle of the scope (row ≈ size/2)
        #expect(abs(nonEmptyRows[0] - size / 2) <= 2)
    }

    @Test func pureRedShowsOnlyRedHistogram() throws {
        let data = try #require(ScopeAnalyzer.analyze(
            makeBGRA(b: 0, g: 0, r: 255)))
        #expect(data.histR.firstIndex(of: data.histR.max()!) == 255)
        #expect(data.histG.firstIndex(of: data.histG.max()!) == 0)
        #expect(data.histB.firstIndex(of: data.histB.max()!) == 0)
        // Rec.709 luma of pure red ≈ 54/256 ≈ 21%
        let lumaPeak = data.histY.firstIndex(of: data.histY.max()!)!
        #expect(abs(lumaPeak - 54) <= 2)
    }

    @Test func analyzes2vuyLuma() throws {
        // 2vuy: Cb Y0 Cr Y1, neutral chroma (128), luma 180
        let width = 320, height = 180
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_422YpCbCr8,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                            &pb)
        let buffer = try #require(pb)
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for pair in 0..<(width / 2) {
                let p = base + y * rowBytes + pair * 4
                p[0] = 128; p[1] = 180; p[2] = 128; p[3] = 180
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        let data = try #require(ScopeAnalyzer.analyze(buffer))
        #expect(data.histY.firstIndex(of: data.histY.max()!) == 180)
        // neutral chroma → R≈G≈B (video-range 180 → ~191 full-range)
        let rPeak = data.histR.firstIndex(of: data.histR.max()!)!
        let gPeak = data.histG.firstIndex(of: data.histG.max()!)!
        #expect(abs(rPeak - gPeak) <= 2)
    }

    @Test func unsupportedFormatReturnsNil() {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 64, 64,
                            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            nil, &pb)
        #expect(ScopeAnalyzer.analyze(pb!) == nil)
    }
}
