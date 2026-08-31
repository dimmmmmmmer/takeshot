import CoreVideo
import Foundation
import Testing

@testable import CaptureCore

/// Scopes measure what the viewer SHOWS. Punched in, that is a crop, and these
/// tests are the proof that the analyzer samples the crop and not the frame: a
/// known horizontal gradient is fed in, and where the trace/histogram lands says
/// exactly which columns were read.
struct ScopeRegionTests {
    /// A left-to-right ramp from 0 to 255 in all three channels — the position
    /// of a sampled column is readable straight off its code value.
    private func gradient(width: Int = 640, height: Int = 360) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                            &pb)
        let buffer = try #require(pb)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer))
            .assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            let row = base + y * rowBytes
            for x in 0..<width {
                let value = UInt8(x * 255 / (width - 1))
                row[x * 4] = value
                row[x * 4 + 1] = value
                row[x * 4 + 2] = value
                row[x * 4 + 3] = 255
            }
        }
        return buffer
    }

    /// Lowest and highest code value with any weight in the luma histogram.
    private func lumaRange(_ data: ScopeData) throws -> (low: Int, high: Int) {
        let occupied = data.histY.indices.filter { data.histY[$0] > 0 }
        return (try #require(occupied.first), try #require(occupied.last))
    }

    @Test func fullFrameCoversTheWholeGradient() throws {
        let data = try #require(ScopeAnalyzer.analyze(try gradient()))
        let range = try lumaRange(data)
        #expect(range.low <= 2)
        #expect(range.high >= 253)
    }

    /// The right half of the gradient holds the top half of the code range —
    /// nothing below ~50% may appear once the analysis is limited to it.
    @Test func aRegionOnlySeesItsOwnColumns() throws {
        let frame = try gradient()
        let right = try #require(ScopeAnalyzer.analyze(
            frame, region: ScopeRegion(x: 0.5, y: 0, width: 0.5, height: 1)))
        let rightRange = try lumaRange(right)
        #expect(rightRange.low >= 124, "the right half started at \(rightRange.low)")
        #expect(rightRange.high >= 253)

        let left = try #require(ScopeAnalyzer.analyze(
            frame, region: ScopeRegion(x: 0, y: 0, width: 0.5, height: 1)))
        let leftRange = try lumaRange(left)
        #expect(leftRange.low <= 2)
        #expect(leftRange.high <= 131, "the left half reached \(leftRange.high)")
    }

    /// The same shift, read off the waveform instead of the histogram: the trace
    /// is drawn left to right over the region, so the first column of a
    /// punched-in trace sits at the region's first code value, not the frame's.
    @Test func theTraceStartsWhereTheRegionStarts() throws {
        let frame = try gradient()
        func firstColumnRow(_ data: ScopeData) throws -> Int {
            let width = ScopeData.waveWidth
            let rows = (0..<ScopeData.waveHeight).filter {
                data.waveformY[$0 * width] > 0
            }
            return try #require(rows.first)
        }
        // row 0 is 100%, the last row is 0%: a brighter first column sits higher
        let full = try #require(ScopeAnalyzer.analyze(frame))
        let punched = try #require(ScopeAnalyzer.analyze(
            frame, region: ScopeRegion(assist: {
                var assist = ViewAssist()
                assist.punchIn = 2
                assist.panX = 0.25 // centered on the right half
                return assist
            }())))
        #expect(try firstColumnRow(punched) < firstColumnRow(full),
                "the punched-in trace should start brighter than the full frame's")
    }

    /// A 2x punch-in shows a quarter of the frame; panning moves that window and
    /// stops at the edges.
    @Test func punchInDerivesTheCenteredQuarter() {
        var assist = ViewAssist()
        assist.punchIn = 2
        let centered = ScopeRegion(assist: assist)
        #expect(centered.width == 0.5)
        #expect(centered.height == 0.5)
        #expect(centered.x == 0.25)
        #expect(centered.y == 0.25)

        assist.panX = 0.25
        assist.panY = -0.25
        let panned = ScopeRegion(assist: assist)
        #expect(panned.x == 0.5)
        #expect(panned.y == 0)

        // the pan is clamped to ±0.5 upstream; the region clamps regardless
        assist.panX = 0.5
        assist.panY = 0.5
        let cornered = ScopeRegion(assist: assist)
        #expect(cornered.x == 0.5)
        #expect(cornered.y == 0.5)
    }

    @Test func noPunchInIsTheWholeFrame() {
        let region = ScopeRegion(assist: ViewAssist())
        #expect(region == .full)
        #expect(region.width == 1 && region.height == 1)
        // punchIn below 1 is off, not a magnification of the letterbox
        var assist = ViewAssist()
        assist.punchIn = 0.5
        #expect(ScopeRegion(assist: assist) == .full)
    }

    /// The pixel window never leaves the plane, whatever it is asked for: the
    /// analyzer reads it with no bounds checking of its own.
    @Test func thePixelWindowStaysInsideTheFrame() {
        let region = ScopeRegion(x: 0.9, y: 0.9, width: 0.5, height: 0.5)
        let window = region.pixels(width: 1920, height: 1080)
        #expect(window.x + window.width <= 1920)
        #expect(window.y + window.height <= 1080)
        #expect(window.width > 0 && window.height > 0)

        // a degenerate region still names at least one pixel
        let sliver = ScopeRegion(x: 1, y: 1, width: 0, height: 0)
        let tiny = sliver.pixels(width: 64, height: 64)
        #expect(tiny.width >= 1 && tiny.height >= 1)
        #expect(tiny.x + tiny.width <= 64)
        #expect(tiny.y + tiny.height <= 64)
    }
}
