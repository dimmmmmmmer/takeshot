import CoreVideo
import Foundation

/// One frame's worth of scope data: per-channel waveform density maps, RGB/luma
/// histograms and a vectorscope density map. Computed on the CPU from a fixed
/// sampling grid — cheap enough to run at ~8 Hz on the pipeline queue.
///
/// Colorimetry: gamma-encoded R'G'B' code values (the standard scope domain),
/// BT.709 luma Y' = 0.2126 R' + 0.7152 G' + 0.0722 B', full-range chroma
/// Cb = (B'−Y')/1.8556, Cr = (R'−Y')/1.5748 — the same math positions the
/// vectorscope graticule targets, so a 75% bar lands exactly on its box.
public struct ScopeData: Sendable {
    /// Waveform trace resolution.
    public static let waveWidth = 512
    public static let waveHeight = 256
    /// Vectorscope resolution (square).
    public static let vectorSize = 256
    /// Grayscale density maps, row-major `waveWidth * waveHeight`;
    /// row 0 is 100% (top of the scope).
    public let waveformY: [UInt8]
    public let waveformR: [UInt8]
    public let waveformG: [UInt8]
    public let waveformB: [UInt8]
    /// Luma waveform colored by the image: RGBA `waveWidth * waveHeight * 4`,
    /// brightness = trace density, chroma = mean color of contributing pixels.
    public let waveformYColor: [UInt8]
    /// 256-bin histograms.
    public let histR: [Int]
    public let histG: [Int]
    public let histB: [Int]
    public let histY: [Int]
    /// Vectorscope density: x = Cb (right = +), y = Cr (top = +), center at
    /// (vectorSize/2, vectorSize/2), full-range chroma ±127 maps to ±half-size.
    public let vector: [UInt8]
    /// Monotonic frame counter — views cache derived images against it so a
    /// window resize doesn't rebuild them.
    public let sequence: Int

    /// Legacy alias (luma waveform).
    public var waveform: [UInt8] { waveformY }
}

/// Computes scope data from capture/playback pixel buffers.
/// Supports 32BGRA, 2vuy and 420v frames.
public enum ScopeAnalyzer {
    /// Full-range BT.709 chroma of gamma-encoded R'G'B' — shared by the
    /// analysis and the vectorscope graticule so targets are exact.
    public static func chroma(r: Double, g: Double, b: Double)
        -> (cb: Double, cr: Double) {
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return ((b - y) / 1.8556, (r - y) / 1.5748)
    }

    private static let sequenceLock = NSLock()
    nonisolated(unsafe) private static var sequenceCounter = 0

    static func nextSequence() -> Int {
        sequenceLock.lock()
        defer { sequenceLock.unlock() }
        sequenceCounter += 1
        return sequenceCounter
    }

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

    /// Fixed sampling grid: identical column population for any frame size
    /// (resolution-dependent striding caused vertical banding).
    static let gridCols = ScopeData.waveWidth
    static let gridRows = 270

    private static func analyzeBGRA(base: UnsafeRawPointer, width: Int,
                                    height: Int, rowBytes: Int) -> ScopeData? {
        guard width > 1, height > 0 else { return nil }
        var acc = Accumulator()
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        for gy in 0..<Self.gridRows {
            let y = gy * height / Self.gridRows
            let row = bytes + y * rowBytes
            for gx in 0..<Self.gridCols {
                let x = gx * width / Self.gridCols
                let p = row + x * 4 // B G R A
                acc.add(col: gx, r: Int(p[2]), g: Int(p[1]), b: Int(p[0]))
            }
        }
        return acc.finish()
    }

    private static func analyze2vuy(base: UnsafeRawPointer, width: Int,
                                    height: Int, rowBytes: Int) -> ScopeData? {
        guard width > 1, height > 0 else { return nil }
        var acc = Accumulator()
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        for gy in 0..<Self.gridRows {
            let y = gy * height / Self.gridRows
            let row = bytes + y * rowBytes
            for gx in 0..<Self.gridCols {
                let x = (gx * width / Self.gridCols) & ~1 // whole Cb Y0 Cr Y1 macropixel
                let p = row + (x / 2) * 4
                let cb = Int(p[0]) - 128
                let luma0 = Int(p[1])
                let cr = Int(p[2]) - 128
                // BT.709 video-range YCbCr → full-range R'G'B'
                let yv = (luma0 - 16) * 298
                let r = clamp((yv + 459 * cr) >> 8)
                let g = clamp((yv - 137 * cr - 55 * cb) >> 8)
                let b = clamp((yv + 541 * cb) >> 8)
                acc.add(col: gx, r: r, g: g, b: b,
                        nativeChroma: (Double(cb) * 255 / 224,
                                       Double(cr) * 255 / 224),
                        nativeLuma: clamp(yv >> 8))
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
        var acc = Accumulator()
        let yp = yBase.assumingMemoryBound(to: UInt8.self)
        let cp = cBase.assumingMemoryBound(to: UInt8.self)
        for gy in 0..<Self.gridRows {
            let y = (gy * height / Self.gridRows) & ~1
            let lumaRow = yp + y * yRow
            let chromaRow = cp + (y / 2) * cRow
            for gx in 0..<Self.gridCols {
                let x = (gx * width / Self.gridCols) & ~1
                let luma0 = Int(lumaRow[x])
                let cb = Int(chromaRow[(x / 2) * 2]) - 128
                let cr = Int(chromaRow[(x / 2) * 2 + 1]) - 128
                let yv = (luma0 - 16) * 298
                let r = clamp((yv + 459 * cr) >> 8)
                let g = clamp((yv - 137 * cr - 55 * cb) >> 8)
                let b = clamp((yv + 541 * cb) >> 8)
                acc.add(col: gx, r: r, g: g, b: b,
                        nativeChroma: (Double(cb) * 255 / 224,
                                       Double(cr) * 255 / 224),
                        nativeLuma: clamp(yv >> 8))
            }
        }
        return acc.finish()
    }

    private static func clamp(_ v: Int) -> Int { min(255, max(0, v)) }

    /// Shared accumulation: everything is derived from full-range gamma-encoded
    /// R'G'B' samples, so all sources land on the same scales.
    private struct Accumulator {
        static let cells = ScopeData.waveWidth * ScopeData.waveHeight
        var countsY = [Int](repeating: 0, count: Self.cells)
        var countsR = [Int](repeating: 0, count: Self.cells)
        var countsG = [Int](repeating: 0, count: Self.cells)
        var countsB = [Int](repeating: 0, count: Self.cells)
        var countsV = [Int](repeating: 0,
                            count: ScopeData.vectorSize * ScopeData.vectorSize)
        var histR = [Int](repeating: 0, count: 256)
        var histG = [Int](repeating: 0, count: 256)
        var histB = [Int](repeating: 0, count: 256)
        var histY = [Int](repeating: 0, count: 256)
        // mean color of the pixels landing in each luma-waveform cell
        var sumR = [Int](repeating: 0, count: Self.cells)
        var sumG = [Int](repeating: 0, count: Self.cells)
        var sumB = [Int](repeating: 0, count: Self.cells)

        /// `nativeChroma`/`nativeLuma`: for YUV sources pass the wire values
        /// (scaled to full range) so illegal chroma/luma excursions are plotted
        /// as-is instead of being folded into the RGB gamut by the clamp.
        // previous sample of the current scanline — traces are drawn as
        // connected vertical segments between neighbours (like a real waveform
        // monitor / Resolve), not scattered dots: this removes both the noise
        // and the horizontal banding from quantization gaps
        private var prevLuma = -1
        private var prevR = -1, prevG = -1, prevB = -1

        mutating func add(col: Int, r: Int, g: Int, b: Int,
                          nativeChroma: (cb: Double, cr: Double)? = nil,
                          nativeLuma: Int? = nil) {
            let width = ScopeData.waveWidth
            let height = ScopeData.waveHeight
            let luma = nativeLuma
                ?? min(255, Int((0.2126 * Double(r) + 0.7152 * Double(g)
                                 + 0.0722 * Double(b)).rounded()))
            histR[r] += 1
            histG[g] += 1
            histB[b] += 1
            histY[luma] += 1

            if col == 0 { prevLuma = -1; prevR = -1; prevG = -1; prevB = -1 }

            func rowFor(_ value: Int) -> Int {
                height - 1 - min(height - 1, value * height / 256)
            }
            // vertical segment from the previous sample's value to this one
            func fillSpan(_ counts: inout [Int], value: Int, prev: Int) {
                let from = prev < 0 ? value : prev
                let lo = rowFor(max(value, from))
                let hi = rowFor(min(value, from))
                for row in lo...hi {
                    counts[row * width + col] += 1
                }
            }
            fillSpan(&countsR, value: r, prev: prevR)
            fillSpan(&countsG, value: g, prev: prevG)
            fillSpan(&countsB, value: b, prev: prevB)
            // luma span carries the pixel color for the colored trace
            let from = prevLuma < 0 ? luma : prevLuma
            let lo = rowFor(max(luma, from))
            let hi = rowFor(min(luma, from))
            for row in lo...hi {
                let idx = row * width + col
                countsY[idx] += 1
                sumR[idx] += r
                sumG[idx] += g
                sumB[idx] += b
            }
            prevLuma = luma; prevR = r; prevG = g; prevB = b

            // vectorscope: full-range BT.709 chroma, ±127 → ±half-size
            let (cb, cr) = nativeChroma
                ?? ScopeAnalyzer.chroma(r: Double(r), g: Double(g), b: Double(b))
            let size = ScopeData.vectorSize
            let vx = min(size - 1, max(0, Int(Double(size) / 2 + cb * Double(size) / 255)))
            let vy = min(size - 1, max(0, Int(Double(size) / 2 - cr * Double(size) / 255)))
            countsV[vy * size + vx] += 1
        }

        func finish() -> ScopeData {
            // sqrt tone curve: a linear gain saturates after a few hits and the
            // trace turns binary; sqrt keeps single hits visible with readable
            // density gradation
            func toBytes(_ counts: [Int], gain: Double) -> [UInt8] {
                counts.map {
                    $0 == 0 ? 0
                        : UInt8(min(255.0, gain * Double($0).squareRoot()))
                }
            }
            // colored luma trace: brightness from density, chroma kept exactly
            // as the image's (no re-saturation)
            var colored = [UInt8](repeating: 0, count: countsY.count * 4)
            for i in 0..<countsY.count {
                let count = countsY[i]
                guard count > 0 else { continue }
                let brightness = min(255.0, 96 * Double(count).squareRoot())
                let avgR = Double(sumR[i]) / Double(count)
                let avgG = Double(sumG[i]) / Double(count)
                let avgB = Double(sumB[i]) / Double(count)
                // scale the mean color so its BT.709 luma equals the trace
                // brightness: hue and saturation stay true to the image
                let avgY = max(1, 0.2126 * avgR + 0.7152 * avgG + 0.0722 * avgB)
                let scale = brightness / avgY
                colored[i * 4] = UInt8(min(255, avgR * scale))
                colored[i * 4 + 1] = UInt8(min(255, avgG * scale))
                colored[i * 4 + 2] = UInt8(min(255, avgB * scale))
                colored[i * 4 + 3] = 255
            }
            // vector: adaptive log curve — a fixed gain either clips into a
            // flat blob or hides low densities
            let vPeak = max(1, countsV.max() ?? 1)
            let vScale = 255.0 / Foundation.log(Double(vPeak) + 1)
            let vectorBytes = countsV.map {
                $0 == 0 ? UInt8(0)
                    : UInt8(min(255.0, vScale * Foundation.log(Double($0) + 1)))
            }
            return ScopeData(waveformY: toBytes(countsY, gain: 96),
                             waveformR: toBytes(countsR, gain: 96),
                             waveformG: toBytes(countsG, gain: 96),
                             waveformB: toBytes(countsB, gain: 96),
                             waveformYColor: colored,
                             histR: histR, histG: histG,
                             histB: histB, histY: histY,
                             vector: vectorBytes,
                             sequence: ScopeAnalyzer.nextSequence())
        }
    }
}
