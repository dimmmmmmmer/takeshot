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
    ///
    /// A class holding raw buffers rather than a struct of `[Int]`s, and the
    /// traces are accumulated as DIFFERENCES instead of filled row by row.
    /// Both changes are about one number: the grid walk measured 123 ms per
    /// 1080p frame on noisy content (5-8 Hz updates, and the pass was busy
    /// through the next two frames the pipeline offered). A sample used to
    /// increment every row of its vertical segment — up to 32 rows in each of
    /// four maps, ~31 M bounds-checked array writes per frame. Marking the two
    /// ends of the segment and integrating each column once at the end is the
    /// same picture, exactly, for a twentieth of the writes.
    final class Accumulator {
        static let width = ScopeData.waveWidth
        static let height = ScopeData.waveHeight
        static let cells = width * height
        /// The difference maps carry one spare row: a segment ending on the
        /// last row marks `row + 1` and must not need a branch to do it.
        static let diffCells = width * (height + 1)
        static let vectorCells = ScopeData.vectorSize * ScopeData.vectorSize

        // Trace densities as difference maps (row-major, `height + 1` rows).
        private let diffY: UnsafeMutablePointer<Int32>
        private let diffR: UnsafeMutablePointer<Int32>
        private let diffG: UnsafeMutablePointer<Int32>
        private let diffB: UnsafeMutablePointer<Int32>
        // Mean color of the pixels landing in each luma-waveform cell, same
        // difference-map layout: a sample adds its color over the rows its
        // luma segment covers.
        private let sumR: UnsafeMutablePointer<Int32>
        private let sumG: UnsafeMutablePointer<Int32>
        private let sumB: UnsafeMutablePointer<Int32>
        /// Vectorscope density — one cell per sample, no segments to fill.
        private let vector: UnsafeMutablePointer<Int32>
        /// The four 256-bin histograms, back to back (R, G, B, Y).
        private let hist: UnsafeMutablePointer<Int32>

        // previous sample of the current scanline — traces are drawn as
        // connected vertical segments between neighbours (like a real waveform
        // monitor / Resolve), not scattered dots: this removes both the noise
        // and the horizontal banding from quantization gaps
        private var prevLuma = -1
        private var prevR = -1, prevG = -1, prevB = -1

        init() {
            func zeroed(_ count: Int) -> UnsafeMutablePointer<Int32> {
                let buffer = UnsafeMutablePointer<Int32>.allocate(capacity: count)
                buffer.initialize(repeating: 0, count: count)
                return buffer
            }
            diffY = zeroed(Self.diffCells)
            diffR = zeroed(Self.diffCells)
            diffG = zeroed(Self.diffCells)
            diffB = zeroed(Self.diffCells)
            sumR = zeroed(Self.diffCells)
            sumG = zeroed(Self.diffCells)
            sumB = zeroed(Self.diffCells)
            vector = zeroed(Self.vectorCells)
            hist = zeroed(4 * 256)
        }

        deinit {
            for buffer in [diffY, diffR, diffG, diffB, sumR, sumG, sumB,
                           vector, hist] {
                buffer.deallocate()
            }
        }

        /// Scope row for a code value: row 0 is 100% at the top of the trace.
        @inline(__always)
        private static func row(for value: Int) -> Int {
            height - 1 - min(height - 1, value * height / 256)
        }

        /// The rows a sample covers: the vertical segment from the previous
        /// sample's value to this one. The span is CAPPED: on noisy content
        /// |value − prev| averages ~85 codes and an unbounded fill measured
        /// 340 ms/pass at UHD — 8+ frame budgets. 32 rows looks identical on
        /// real traces.
        private static let maxSpan = 32

        /// Top and one-past-bottom row of the segment ending at `value`.
        @inline(__always)
        private static func segment(value: Int, prev: Int) -> (top: Int, end: Int) {
            let from = prev < 0 ? value
                : min(max(prev, value - maxSpan), value + maxSpan)
            return (row(for: max(value, from)), row(for: min(value, from)) + 1)
        }

        /// Mark one channel's segment in its difference map.
        @inline(__always)
        private func mark(_ diff: UnsafeMutablePointer<Int32>, col: Int,
                          value: Int, prev: Int) {
            let span = Self.segment(value: value, prev: prev)
            diff[span.top * Self.width + col] += 1
            diff[span.end * Self.width + col] -= 1
        }

        // `nativeChroma`/`nativeLuma`: for YUV sources pass the wire values
        // (scaled to full range) so illegal chroma/luma excursions are plotted
        // as-is instead of being folded into the RGB gamut by the clamp.
        func add(col: Int, r: Int, g: Int, b: Int,
                 nativeChroma: (cb: Double, cr: Double)? = nil,
                 nativeLuma: Int? = nil) {
            let luma = nativeLuma
                ?? min(255, Int((0.2126 * Double(r) + 0.7152 * Double(g)
                                 + 0.0722 * Double(b)).rounded()))
            hist[r] += 1
            hist[256 + g] += 1
            hist[512 + b] += 1
            hist[768 + luma] += 1

            if col == 0 { prevLuma = -1; prevR = -1; prevG = -1; prevB = -1 }

            mark(diffR, col: col, value: r, prev: prevR)
            mark(diffG, col: col, value: g, prev: prevG)
            mark(diffB, col: col, value: b, prev: prevB)
            // the luma segment is marked by hand rather than through `mark`:
            // it also carries the pixel color for the colored trace
            let span = Self.segment(value: luma, prev: prevLuma)
            let top = span.top * Self.width + col
            let end = span.end * Self.width + col
            diffY[top] += 1
            diffY[end] -= 1
            sumR[top] += Int32(r); sumR[end] -= Int32(r)
            sumG[top] += Int32(g); sumG[end] -= Int32(g)
            sumB[top] += Int32(b); sumB[end] -= Int32(b)
            prevLuma = luma; prevR = r; prevG = g; prevB = b

            // vectorscope: full-range BT.709 chroma, ±127 → ±half-size
            let (cb, cr) = nativeChroma
                ?? ScopeAnalyzer.chroma(r: Double(r), g: Double(g), b: Double(b))
            let size = ScopeData.vectorSize
            let vx = min(size - 1, max(0, Int(Double(size) / 2 + cb * Double(size) / 255)))
            let vy = min(size - 1, max(0, Int(Double(size) / 2 - cr * Double(size) / 255)))
            vector[vy * size + vx] += 1
        }

        /// Integrate a difference map down its columns — the running total IS
        /// the density. Both reads walk the buffer front to back, so this is a
        /// sequential sweep however tall the map is.
        private static func integrated(
            _ diff: UnsafeMutablePointer<Int32>) -> [Int32] {
            var out = [Int32](repeating: 0, count: cells)
            out.withUnsafeMutableBufferPointer { dst in
                for col in 0..<width { dst[col] = diff[col] }
                var base = width
                for _ in 1..<height {
                    for col in 0..<width {
                        dst[base + col] = dst[base - width + col] + diff[base + col]
                    }
                    base += width
                }
            }
            return out
        }

        /// Separable 1-2-1 blur over the density map: CRT-like soft traces
        /// instead of hard single-pixel lines (the "noisy" look).
        static func blurred(_ counts: [Int32]) -> [Int32] {
            let row = (step: 1, count: width)
            let column = (step: width, count: height)
            // across every row, then down every column
            return blurPass(blurPass(counts, along: row, across: column),
                            along: column, across: row)
        }

        /// One pass of the separable blur. `along` is the direction being
        /// blurred (step between neighbours, samples per line), `across` walks
        /// the line starts — so the two passes are the same code with the two
        /// descriptions swapped, and neither borrows across a line end.
        private static func blurPass(_ counts: [Int32],
                                     along: (step: Int, count: Int),
                                     across: (step: Int, count: Int)) -> [Int32] {
            var out = [Int32](repeating: 0, count: counts.count)
            counts.withUnsafeBufferPointer { src in
                out.withUnsafeMutableBufferPointer { dst in
                    for line in 0..<across.count {
                        let start = line * across.step
                        for position in 0..<along.count {
                            let index = start + position * along.step
                            let before = position > 0 ? src[index - along.step] : 0
                            let after = position < along.count - 1
                                ? src[index + along.step] : 0
                            dst[index] = src[index] * 2 + before + after
                        }
                    }
                }
            }
            return out
        }

        /// log(count + 1) for the densities that actually occur, precomputed.
        /// Every cell of every map used to call `Foundation.log` twice (once for
        /// the byte, once for the colored trace) — 600 k transcendental calls
        /// per frame for a 255-level output.
        /// Covers every density a blurred trace map can reach (the grid puts
        /// `gridRows` samples in a column and the two blur passes multiply by
        /// 16); the vectorscope's few hottest cells fall through to `log`.
        private static let logTable: [Double] =
            (0...8192).map { Foundation.log(Double($0) + 1) }

        @inline(__always)
        private static func logOf(_ count: Int32) -> Double {
            let index = Int(count)
            return index <= 8192 ? logTable[index]
                : Foundation.log(Double(index) + 1)
        }

        /// Adaptive log curve, for the waveforms and the vectorscope alike:
        /// single hits stay visible and dense areas keep their gradation, where
        /// a fixed gain either clips into a flat blob or hides the low
        /// densities.
        private static func toBytesLog(_ counts: [Int32]) -> [UInt8] {
            let peak = max(1, counts.max() ?? 1)
            let scale = 255.0 / logOf(peak)
            var out = [UInt8](repeating: 0, count: counts.count)
            counts.withUnsafeBufferPointer { src in
                out.withUnsafeMutableBufferPointer { dst in
                    for i in 0..<src.count where src[i] != 0 {
                        dst[i] = UInt8(min(255.0, scale * logOf(src[i])))
                    }
                }
            }
            return out
        }

        func finish() -> ScopeData {
            let softY = Self.blurred(Self.integrated(diffY))
            // colored luma trace: brightness from the softened density (log),
            // chroma from the blurred means so color follows the soft edge
            let colored = coloredTrace(density: softY)
            return ScopeData(
                waveformY: Self.toBytesLog(softY),
                waveformR: Self.toBytesLog(Self.blurred(Self.integrated(diffR))),
                waveformG: Self.toBytesLog(Self.blurred(Self.integrated(diffG))),
                waveformB: Self.toBytesLog(Self.blurred(Self.integrated(diffB))),
                waveformYColor: colored,
                histR: histogram(0), histG: histogram(1),
                histB: histogram(2), histY: histogram(3),
                vector: Self.toBytesLog(
                    Array(UnsafeBufferPointer(start: vector,
                                              count: Self.vectorCells))),
                sequence: ScopeAnalyzer.nextSequence())
        }

        private func histogram(_ index: Int) -> [Int] {
            UnsafeBufferPointer(start: hist + index * 256, count: 256).map(Int.init)
        }

        /// RGBA luma trace: brightness from the density, hue and saturation
        /// from the mean color of the pixels that made it.
        private func coloredTrace(density: [Int32]) -> [UInt8] {
            let colorR = Self.blurred(Self.integrated(sumR))
            let colorG = Self.blurred(Self.integrated(sumG))
            let colorB = Self.blurred(Self.integrated(sumB))
            var colored = [UInt8](repeating: 0, count: Self.cells * 4)
            let yScale = 255.0 / Self.logOf(max(1, density.max() ?? 1))
            for i in 0..<Self.cells {
                let count = density[i]
                guard count > 0 else { continue }
                let brightness = min(255.0, yScale * Self.logOf(count))
                let avgR = Double(colorR[i]) / Double(count)
                let avgG = Double(colorG[i]) / Double(count)
                let avgB = Double(colorB[i]) / Double(count)
                // scale the mean color so its BT.709 luma equals the trace
                // brightness: hue and saturation stay true to the image
                let avgY = max(1, 0.2126 * avgR + 0.7152 * avgG + 0.0722 * avgB)
                let scale = brightness / avgY
                colored[i * 4] = UInt8(min(255, avgR * scale))
                colored[i * 4 + 1] = UInt8(min(255, avgG * scale))
                colored[i * 4 + 2] = UInt8(min(255, avgB * scale))
                colored[i * 4 + 3] = 255
            }
            return colored
        }
    }
}
