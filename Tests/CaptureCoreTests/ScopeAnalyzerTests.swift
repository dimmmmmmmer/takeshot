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
        // the trace sits on one luma row; the 1-2-1 softening bleeds one row
        // to each side, so up to three, centered on the true value
        let width = ScopeData.waveWidth
        let height = ScopeData.waveHeight
        let nonEmptyRows = (0..<height).filter { row in
            (0..<width).contains { data.waveform[row * width + $0] > 0 }
        }
        #expect((1...3).contains(nonEmptyRows.count))
        // 128/255 luma → the middle of the scope (row ≈ height/2)
        let center = nonEmptyRows[nonEmptyRows.count / 2]
        #expect(abs(center - height / 2) <= 2)
        // the true row must dominate its soft edges
        let rowMax = nonEmptyRows.map { row in
            (0..<width).map { Int(data.waveform[row * width + $0]) }.max() ?? 0
        }
        #expect(rowMax.max() == rowMax[nonEmptyRows.count / 2])
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
        // luma is normalized to full range like the BGRA path:
        // video-range 180 → (180-16)*298>>8 = 190
        #expect(data.histY.firstIndex(of: data.histY.max()!) == 190)
        // neutral chroma → R≈G≈B (video-range 180 → ~191 full-range)
        let rPeak = data.histR.firstIndex(of: data.histR.max()!)!
        let gPeak = data.histG.firstIndex(of: data.histG.max()!)!
        #expect(abs(rPeak - gPeak) <= 2)
    }

    @Test func unsupportedFormatReturnsNil() {
        // 420v is supported now (playback/preview frames) — use a format the
        // analyzer genuinely does not handle
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 64, 64,
                            kCVPixelFormatType_OneComponent8,
                            nil, &pb)
        #expect(ScopeAnalyzer.analyze(pb!) == nil)
    }
}
