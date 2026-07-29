import Foundation

/// The scope accumulator: one pass over the sampling grid fills the waveform,
/// histogram and vectorscope densities, and `finish()` turns them into a
/// `ScopeData`.
///
/// Split out of ScopeAnalyzer, whose body had grown past the point where the
/// three source-format readers at the top were still visible next to it.
/// Internal rather than private: the readers that feed it live in the other
/// file.
extension ScopeAnalyzer {
    /// Shared accumulation: everything is derived from full-range gamma-encoded
    /// R'G'B' samples, so all sources land on the same scales.
    struct Accumulator {
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

        // `nativeChroma`/`nativeLuma`: for YUV sources pass the wire values
        // (scaled to full range) so illegal chroma/luma excursions are plotted
        // as-is instead of being folded into the RGB gamut by the clamp.
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
            // vertical segment from the previous sample's value to this one.
            // The span is CAPPED: on noisy content |value − prev| averages
            // ~85 codes and an unbounded fill measured 340 ms/pass at UHD —
            // 8+ frame budgets. 32 rows looks identical on real traces.
            let maxSpan = 32
            func fillSpan(_ counts: inout [Int], value: Int, prev: Int) {
                let from = prev < 0 ? value
                    : min(max(prev, value - maxSpan), value + maxSpan)
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
            let from = prevLuma < 0 ? luma
                : min(max(prevLuma, luma - maxSpan), luma + maxSpan)
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

        /// Separable 1-2-1 blur over the density map: CRT-like soft traces
        /// instead of hard single-pixel lines (the "noisy" look).
        static func blurred(_ counts: [Int]) -> [Int] {
            let width = ScopeData.waveWidth
            let height = ScopeData.waveHeight
            var tmp = [Int](repeating: 0, count: counts.count)
            for row in 0..<height {
                let base = row * width
                for col in 0..<width {
                    let left = col > 0 ? counts[base + col - 1] : 0
                    let right = col < width - 1 ? counts[base + col + 1] : 0
                    tmp[base + col] = counts[base + col] * 2 + left + right
                }
            }
            var out = [Int](repeating: 0, count: counts.count)
            for row in 0..<height {
                let base = row * width
                for col in 0..<width {
                    let up = row > 0 ? tmp[base - width + col] : 0
                    let down = row < height - 1 ? tmp[base + width + col] : 0
                    out[base + col] = tmp[base + col] * 2 + up + down
                }
            }
            return out
        }

        func finish() -> ScopeData {
            // adaptive log curve — the same treatment as the vectorscope:
            // single hits stay visible, dense areas keep gradation instead
            // of clipping into a binary trace
            func toBytesLog(_ counts: [Int]) -> [UInt8] {
                let peak = max(1, counts.max() ?? 1)
                let scale = 255.0 / Foundation.log(Double(peak) + 1)
                return counts.map {
                    $0 == 0 ? 0
                        : UInt8(min(255.0, scale * Foundation.log(Double($0) + 1)))
                }
            }
            let softY = Self.blurred(countsY)
            let softR = Self.blurred(countsR)
            let softG = Self.blurred(countsG)
            let softB = Self.blurred(countsB)
            // colored luma trace: brightness from the softened density (log),
            // chroma from the blurred means so color follows the soft edge
            let colorR = Self.blurred(sumR)
            let colorG = Self.blurred(sumG)
            let colorB = Self.blurred(sumB)
            var colored = [UInt8](repeating: 0, count: countsY.count * 4)
            let yPeak = max(1, softY.max() ?? 1)
            let yScale = 255.0 / Foundation.log(Double(yPeak) + 1)
            for i in 0..<countsY.count {
                let density = softY[i]
                guard density > 0 else { continue }
                let brightness = min(255.0,
                                     yScale * Foundation.log(Double(density) + 1))
                let avgR = Double(colorR[i]) / Double(density)
                let avgG = Double(colorG[i]) / Double(density)
                let avgB = Double(colorB[i]) / Double(density)
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
            return ScopeData(waveformY: toBytesLog(softY),
                             waveformR: toBytesLog(softR),
                             waveformG: toBytesLog(softG),
                             waveformB: toBytesLog(softB),
                             waveformYColor: colored,
                             histR: histR, histG: histG,
                             histB: histB, histY: histY,
                             vector: vectorBytes,
                             sequence: ScopeAnalyzer.nextSequence())
        }
    }
}
