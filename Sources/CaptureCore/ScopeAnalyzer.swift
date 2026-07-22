import CoreVideo
import Foundation

/// One frame's worth of scope data: a luma waveform density map + RGB/luma
/// histograms. Computed on the CPU from a strided sample of the frame —
/// cheap enough to run at ~8 Hz on the pipeline queue.
public struct ScopeData: Sendable {
    /// Waveform resolution (width = columns, height = luma bins).
    public static let size = 256
    /// Grayscale density map, row-major `size * size`; row 0 is 100% luma
    /// (top of the scope), row 255 is 0%.
    public let waveform: [UInt8]
    /// 256-bin histograms.
    public let histR: [Int]
    public let histG: [Int]
    public let histB: [Int]
    public let histY: [Int]
}

/// Computes scope data from capture/playback pixel buffers.
/// Supports 32BGRA (processed/demo/playback frames) and 2vuy (raw DeckLink YUV).
public enum ScopeAnalyzer {
    public static func analyze(_ pixelBuffer: CVPixelBuffer) -> ScopeData? {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 1, height > 0 else { return nil }

        switch format {
        case kCVPixelFormatType_32BGRA:
            return analyzeBGRA(base: base, width: width, height: height,
                               rowBytes: rowBytes)
        case kCVPixelFormatType_422YpCbCr8: // '2vuy': Cb Y0 Cr Y1
            return analyze2vuy(base: base, width: width, height: height,
                               rowBytes: rowBytes)
        default:
            return nil
        }
    }

    // MARK: - private

    private static func analyzeBGRA(base: UnsafeRawPointer, width: Int,
                                    height: Int, rowBytes: Int) -> ScopeData {
        var acc = Accumulator(width: width)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        // stride the samples so a 4K frame costs about the same as HD
        let stepX = max(1, width / 512)
        let stepY = max(1, height / 270)
        var y = 0
        while y < height {
            let row = bytes + y * rowBytes
            var x = 0
            while x < width {
                let p = row + x * 4 // B G R A
                let b = Int(p[0]), g = Int(p[1]), r = Int(p[2])
                // Rec.709 luma from gamma-encoded values — standard scope behavior
                let luma = (54 * r + 183 * g + 19 * b) >> 8
                acc.add(x: x, r: r, g: g, b: b, luma: luma)
                x += stepX
            }
            y += stepY
        }
        return acc.finish()
    }

    private static func analyze2vuy(base: UnsafeRawPointer, width: Int,
                                    height: Int, rowBytes: Int) -> ScopeData {
        var acc = Accumulator(width: width)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        // sample whole Cb Y0 Cr Y1 macropixels (2 px each)
        let stepX = max(2, (width / 512) & ~1)
        let stepY = max(1, height / 270)
        var y = 0
        while y < height {
            let row = bytes + y * rowBytes
            var x = 0
            while x + 1 < width {
                let p = row + (x / 2) * 4
                let cb = Int(p[0]) - 128
                let luma0 = Int(p[1])
                let cr = Int(p[2]) - 128
                // BT.709 video-range YCbCr → R'G'B' (scaled to 0-255, clamped)
                let yv = (Int(luma0) - 16) * 298
                let r = clamp((yv + 459 * cr) >> 8)
                let g = clamp((yv - 137 * cr - 55 * cb) >> 8)
                let b = clamp((yv + 541 * cb) >> 8)
                acc.add(x: x, r: r, g: g, b: b, luma: luma0)
                x += stepX
            }
            y += stepY
        }
        return acc.finish()
    }

    private static func clamp(_ v: Int) -> Int { min(255, max(0, v)) }

    /// Shared accumulation: waveform density + histograms.
    private struct Accumulator {
        let width: Int
        var counts = [Int](repeating: 0, count: ScopeData.size * ScopeData.size)
        var histR = [Int](repeating: 0, count: 256)
        var histG = [Int](repeating: 0, count: 256)
        var histB = [Int](repeating: 0, count: 256)
        var histY = [Int](repeating: 0, count: 256)

        init(width: Int) { self.width = width }

        mutating func add(x: Int, r: Int, g: Int, b: Int, luma: Int) {
            histR[r] += 1
            histG[g] += 1
            histB[b] += 1
            histY[luma] += 1
            let col = x * ScopeData.size / width
            let rowIdx = ScopeData.size - 1 - luma * ScopeData.size / 256
            counts[rowIdx * ScopeData.size + col] += 1
        }

        func finish() -> ScopeData {
            // fixed gain: typical HD sampling lands ~4-10 hits per waveform cell,
            // so *24 gives a readable trace with visible density variation
            let waveform = counts.map { UInt8(min(255, $0 * 24)) }
            return ScopeData(waveform: waveform, histR: histR, histG: histG,
                             histB: histB, histY: histY)
        }
    }
}
