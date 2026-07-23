import CoreVideo
import Foundation

/// One frame's worth of scope data: per-channel waveform density maps, RGB/luma
/// histograms and a vectorscope density map. Computed on the CPU from a strided
/// sample of the frame — cheap enough to run at ~8 Hz on the pipeline queue.
public struct ScopeData: Sendable {
    /// Waveform resolution (width = columns, height = value bins).
    public static let size = 256
    /// Grayscale density maps, row-major `size * size`; row 0 is 100%
    /// (top of the scope), row 255 is 0%.
    public let waveformY: [UInt8]
    public let waveformR: [UInt8]
    public let waveformG: [UInt8]
    public let waveformB: [UInt8]
    /// 256-bin histograms.
    public let histR: [Int]
    public let histG: [Int]
    public let histB: [Int]
    public let histY: [Int]
    /// Vectorscope density map: x = Cb, y = Cr (128;128 at the center),
    /// row-major `size * size`, row 0 = Cr 255.
    public let vector: [UInt8]

    /// Legacy alias (luma waveform).
    public var waveform: [UInt8] { waveformY }
}

/// Computes scope data from capture/playback pixel buffers.
/// Supports 32BGRA, 2vuy and 420v frames.
public enum ScopeAnalyzer {
    public static func analyze(_ pixelBuffer: CVPixelBuffer) -> ScopeData? {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        switch format {
        case kCVPixelFormatType_32BGRA:
            guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
            return analyzeBGRA(base: base,
                               width: CVPixelBufferGetWidth(pixelBuffer),
                               height: CVPixelBufferGetHeight(pixelBuffer),
                               rowBytes: CVPixelBufferGetBytesPerRow(pixelBuffer))
        case kCVPixelFormatType_422YpCbCr8: // '2vuy': Cb Y0 Cr Y1
            guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
            return analyze2vuy(base: base,
                               width: CVPixelBufferGetWidth(pixelBuffer),
                               height: CVPixelBufferGetHeight(pixelBuffer),
                               rowBytes: CVPixelBufferGetBytesPerRow(pixelBuffer))
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: // '420v'
            return analyze420v(pixelBuffer)
        default:
            return nil
        }
    }

    // MARK: - private

    /// Fixed sampling grid: exactly `gridCols`×`gridRows` samples for any frame
    /// size, so every waveform column gets the same number of hits — resolution-
    /// dependent striding caused visible vertical banding.
    static let gridCols = 512
    static let gridRows = 270

    private static func analyzeBGRA(base: UnsafeRawPointer, width: Int,
                                    height: Int, rowBytes: Int) -> ScopeData? {
        guard width > 1, height > 0 else { return nil }
        var acc = Accumulator(width: Self.gridCols)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        for gy in 0..<Self.gridRows {
            let y = gy * height / Self.gridRows
            let row = bytes + y * rowBytes
            for gx in 0..<Self.gridCols {
                let x = gx * width / Self.gridCols
                let p = row + x * 4 // B G R A
                let b = Int(p[0]), g = Int(p[1]), r = Int(p[2])
                // Rec.709 luma from gamma-encoded values — standard scope behavior
                let luma = (54 * r + 183 * g + 19 * b) >> 8
                // BT.709 chroma (full-range approximation) for the vectorscope
                let cb = clamp(128 + ((b - luma) * 138) >> 8, lo: 0, hi: 255)
                let cr = clamp(128 + ((r - luma) * 163) >> 8, lo: 0, hi: 255)
                acc.add(x: gx, r: r, g: g, b: b, luma: luma, cb: cb, cr: cr)
            }
        }
        return acc.finish()
    }

    private static func analyze2vuy(base: UnsafeRawPointer, width: Int,
                                    height: Int, rowBytes: Int) -> ScopeData? {
        guard width > 1, height > 0 else { return nil }
        var acc = Accumulator(width: Self.gridCols)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        for gy in 0..<Self.gridRows {
            let y = gy * height / Self.gridRows
            let row = bytes + y * rowBytes
            for gx in 0..<Self.gridCols {
                let x = (gx * width / Self.gridCols) & ~1 // whole Cb Y0 Cr Y1 macropixel
                let p = row + (x / 2) * 4
                let cbRaw = Int(p[0])
                let luma0 = Int(p[1])
                let crRaw = Int(p[2])
                let cb = cbRaw - 128
                let cr = crRaw - 128
                // BT.709 video-range YCbCr → R'G'B' (scaled to 0-255, clamped)
                let yv = (luma0 - 16) * 298
                let r = clamp((yv + 459 * cr) >> 8)
                let g = clamp((yv - 137 * cr - 55 * cb) >> 8)
                let b = clamp((yv + 541 * cb) >> 8)
                // luma on the same full-range scale as the BGRA path — otherwise
                // the waveform/histogram of a legal-range source never reaches
                // 0/100% and reads as low contrast next to processed frames
                let luma = clamp(yv >> 8)
                acc.add(x: gx, r: r, g: g, b: b, luma: luma, cb: cbRaw, cr: crRaw)
            }
        }
        return acc.finish()
    }

    /// Biplanar 4:2:0 video-range: luma plane + interleaved CbCr plane.
    private static func analyze420v(_ pixelBuffer: CVPixelBuffer) -> ScopeData? {
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let cBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)
        else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let yRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let cRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        guard width > 1, height > 0 else { return nil }
        var acc = Accumulator(width: Self.gridCols)
        let yp = yBase.assumingMemoryBound(to: UInt8.self)
        let cp = cBase.assumingMemoryBound(to: UInt8.self)
        for gy in 0..<Self.gridRows {
            let y = (gy * height / Self.gridRows) & ~1
            let lumaRow = yp + y * yRow
            let chromaRow = cp + (y / 2) * cRow
            for gx in 0..<Self.gridCols {
                let x = (gx * width / Self.gridCols) & ~1
                let luma0 = Int(lumaRow[x])
                let cbRaw = Int(chromaRow[(x / 2) * 2])
                let crRaw = Int(chromaRow[(x / 2) * 2 + 1])
                let cb = cbRaw - 128
                let cr = crRaw - 128
                let yv = (luma0 - 16) * 298
                let r = clamp((yv + 459 * cr) >> 8)
                let g = clamp((yv - 137 * cr - 55 * cb) >> 8)
                let b = clamp((yv + 541 * cb) >> 8)
                let luma = clamp(yv >> 8)
                acc.add(x: gx, r: r, g: g, b: b, luma: luma, cb: cbRaw, cr: crRaw)
            }
        }
        return acc.finish()
    }

    private static func clamp(_ v: Int) -> Int { min(255, max(0, v)) }
    private static func clamp(_ v: Int, lo: Int, hi: Int) -> Int { min(hi, max(lo, v)) }

    /// Shared accumulation: waveform densities + histograms + vectorscope.
    private struct Accumulator {
        let width: Int
        var countsY = [Int](repeating: 0, count: ScopeData.size * ScopeData.size)
        var countsR = [Int](repeating: 0, count: ScopeData.size * ScopeData.size)
        var countsG = [Int](repeating: 0, count: ScopeData.size * ScopeData.size)
        var countsB = [Int](repeating: 0, count: ScopeData.size * ScopeData.size)
        var countsV = [Int](repeating: 0, count: ScopeData.size * ScopeData.size)
        var histR = [Int](repeating: 0, count: 256)
        var histG = [Int](repeating: 0, count: 256)
        var histB = [Int](repeating: 0, count: 256)
        var histY = [Int](repeating: 0, count: 256)

        init(width: Int) { self.width = width }

        mutating func add(x: Int, r: Int, g: Int, b: Int, luma: Int, cb: Int, cr: Int) {
            histR[r] += 1
            histG[g] += 1
            histB[b] += 1
            histY[luma] += 1
            let col = x * ScopeData.size / width
            let size = ScopeData.size
            countsY[(size - 1 - luma * size / 256) * size + col] += 1
            countsR[(size - 1 - r * size / 256) * size + col] += 1
            countsG[(size - 1 - g * size / 256) * size + col] += 1
            countsB[(size - 1 - b * size / 256) * size + col] += 1
            countsV[(size - 1 - cr * size / 256) * size + cb * size / 256] += 1
        }

        func finish() -> ScopeData {
            // fixed gain: the 512×270 grid lands ~2 hits per waveform cell on
            // flat areas, so *24 gives a readable trace with density variation
            func toBytes(_ counts: [Int], gain: Int) -> [UInt8] {
                counts.map { UInt8(min(255, $0 * gain)) }
            }
            return ScopeData(waveformY: toBytes(countsY, gain: 24),
                             waveformR: toBytes(countsR, gain: 24),
                             waveformG: toBytes(countsG, gain: 24),
                             waveformB: toBytes(countsB, gain: 24),
                             histR: histR, histG: histG,
                             histB: histB, histY: histY,
                             vector: toBytes(countsV, gain: 40))
        }
    }
}
