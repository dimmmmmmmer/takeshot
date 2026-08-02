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
    /// Shared accumulation: everything is derived from 10-bit gamma-encoded
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
        static let vectorSize = ScopeData.vectorSize
        static let vectorCells = vectorSize * vectorSize

        /// What the wire codes mean, for the nominal range `finish()` publishes
        /// and for the vectorscope's chroma gain.
        private let levels: ScopeWireLevels
        private let chromaGain: Double

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
        // and the horizontal banding from quantization gaps. It is also what
        // makes a near-flat gradient read as a smooth span rather than a dotted
        // staircase — every pair of adjacent columns is joined, so the only
        // steps left in the trace are the ones the signal actually has.
        private var prevLuma = -1
        private var prevR = -1, prevG = -1, prevB = -1

        init(levels: ScopeWireLevels = .full) {
            self.levels = levels
            chromaGain = levels.chromaGain
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

        /// Scope row for a 10-bit code value: row 0 is the top of the trace.
        @inline(__always)
        static func row(for value: Int) -> Int {
            height - 1
                - min(height - 1, value * height / ScopeAnalyzer.sampleLevels)
        }

        /// Where a 10-bit code sits on the map, 0 = top row, 1 = bottom row.
        /// The graticule is placed through this, so a nominal line lands on the
        /// row the trace for that code actually occupies.
        static func unit(of code: Int) -> Double {
            Double(row(for: code)) / Double(height - 1)
        }

        /// The rows a sample covers: the vertical segment from the previous
        /// sample's value to this one. The span is CAPPED: on noisy content
        /// |value − prev| averages a third of the scale and an unbounded fill
        /// measured 340 ms/pass at UHD back when a segment was filled row by
        /// row. An eighth of the scale looks identical on real traces, and the
        /// cap still bounds how far one noisy sample can smear a column.
        private static let maxSpan = ScopeAnalyzer.sampleLevels / 8

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
                ?? min(ScopeAnalyzer.sampleLevels - 1,
                       Int((0.2126 * Double(r) + 0.7152 * Double(g)
                            + 0.0722 * Double(b)).rounded()))
            // 256 bins over the 10-bit scale: a histogram with 1024 of them is
            // a comb on any real signal, and 256 is already more points than
            // the box it is drawn in has pixels across
            hist[r >> 2] += 1
            hist[256 + (g >> 2)] += 1
            hist[512 + (b >> 2)] += 1
            hist[768 + (luma >> 2)] += 1

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

            addToVector(r: r, g: g, b: b, nativeChroma: nativeChroma)
        }

        /// Vectorscope: full-range BT.709 chroma, ±(scale/2) → ±half-size.
        /// `chromaGain` puts an unexpanded wire frame back on the full-range
        /// scale the graticule targets are positioned on.
        @inline(__always)
        private func addToVector(r: Int, g: Int, b: Int,
                                 nativeChroma: (cb: Double, cr: Double)?) {
            let raw = nativeChroma
                ?? ScopeAnalyzer.chroma(r: Double(r), g: Double(g), b: Double(b))
            let cb = raw.cb * chromaGain, cr = raw.cr * chromaGain
            let size = Self.vectorSize
            let span = Double(ScopeAnalyzer.sampleLevels - 1)
            let vx = min(size - 1, max(0, Int(Double(size) / 2 + cb * Double(size) / span)))
            let vy = min(size - 1, max(0, Int(Double(size) / 2 - cr * Double(size) / span)))
            vector[vy * size + vx] += 1
        }

        /// A difference map all the way to its softened density, in ONE sweep:
        /// the column integration and the vertical 1-2-1 together.
        ///
        /// The VERTICAL blur of a prefix sum is expressible in terms of the sum
        /// and the two differences bracketing it,
        /// `J[y] = I[y−1] + 2·I[y] + I[y+1] = 4·I[y] − d[y] + d[y+1]`, and both
        /// differences are already being read to compute `I[y]` — so the blur
        /// costs two adds on a value that is in a register, instead of a second
        /// pass over a megabyte.
        ///
        /// The map's spare row makes the bottom edge come out right with no
        /// branch — every segment is closed by the time the walk ends, so
        /// `d[height]` is exactly −I[height−1] and the formula degenerates to
        /// the zero-padded `3·I[h−1] − d[h−1]` on its own. The top edge does the
        /// same with `I[−1] = 0`.
        ///
        /// There is deliberately NO horizontal blur here, and that is the fix
        /// for the waveform reading thick and hazy next to the parade. It filled
        /// nothing: the accumulator writes EVERY column for every grid row (a
        /// sample's segment reaches back to its left-hand neighbour's value), so
        /// a trace map has no horizontal gaps for a blur to close — the pass
        /// only widened the trace by a column each way. A column is sub-pixel in
        /// a parade, whose three channels squeeze the whole map into a third of
        /// the box, and it is several device pixels in a waveform, which
        /// stretches one map across all of it. Same code, same map, and the
        /// smear it added was invisible in one scope and the dominant blur in
        /// the other. Measured on a detailed 1080p frame in a 472 pt box, the
        /// horizontal detail surviving to the screen went from 0.35 of the
        /// parade's to 0.57 with the pass gone, and to 1.05 once the map was
        /// widened to match.
        private static func softened(
            _ diff: UnsafeMutablePointer<Int32>) -> [Int32] {
            // one running total per column: 4 KB, so it stays in L1 for the
            // whole sweep. Walking columns instead would stride a megabyte per
            // step.
            var running = [Int32](repeating: 0, count: width)
            return Array(unsafeUninitializedCapacity: cells) { dst, count in
                count = cells
                running.withUnsafeMutableBufferPointer { totals in
                    for y in 0..<height {
                        softenRow(y, diff: diff, totals: totals, into: dst)
                    }
                }
            }
        }

        /// One row of `softened`: integrate down into it, blurring as it goes.
        @inline(__always)
        private static func softenRow(
            _ y: Int, diff: UnsafeMutablePointer<Int32>,
            totals: UnsafeMutableBufferPointer<Int32>,
            into dst: UnsafeMutableBufferPointer<Int32>) {
            let base = y * width
            for col in 0..<width {
                let here = diff[base + col]
                totals[col] += here
                dst[base + col] = 4 * totals[col] - here + diff[base + width + col]
            }
        }

        /// Separable 1-2-1 blur over the vectorscope's square density map.
        ///
        /// The trace maps do NOT go through this. They have one integration
        /// sweep that carries their vertical softening, and they need no
        /// horizontal one (see `softened`). The vectorscope is the opposite
        /// case: one sample per cell, no segments, real gaps between the hits
        /// in both directions — so it gets the full separable blur.
        static func blurred(_ counts: [Int32], size: Int) -> [Int32] {
            let row = (step: 1, count: size)
            let column = (step: size, count: size)
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
            counts.withUnsafeBufferPointer { src in
                Array(unsafeUninitializedCapacity: counts.count) { dst, written in
                    written = counts.count
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
        }

        /// log(count + 1) for the densities that actually occur, precomputed.
        /// Every cell of every map used to call `Foundation.log` twice (once for
        /// the byte, once for the colored trace) — 600 k transcendental calls
        /// per frame for a 255-level output.
        /// Covers every density a softened trace map can reach (the grid puts
        /// `gridRows` samples in a column and the vertical 1-2-1 multiplies by
        /// 4); the vectorscope's few hottest cells fall through to `log`.
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
            let softY = Self.softened(diffY)
            // colored luma trace: brightness from the softened density (log),
            // chroma from the blurred means so color follows the soft edge
            let colored = coloredTrace(density: softY)
            let codes = levels.nominalCodes
            return ScopeData(
                waveformY: Self.toBytesLog(softY),
                waveformR: Self.toBytesLog(Self.softened(diffR)),
                waveformG: Self.toBytesLog(Self.softened(diffG)),
                waveformB: Self.toBytesLog(Self.softened(diffB)),
                waveformYColor: colored,
                histR: histogram(0), histG: histogram(1),
                histB: histogram(2), histY: histogram(3),
                // the vectorscope is softened in both directions: one sample per
                // cell and no segments to fill left it a field of hard dots
                // that read as a low-resolution scope rather than as a density
                vector: Self.toBytesLog(Self.blurred(
                    Array(UnsafeBufferPointer(start: vector,
                                              count: Self.vectorCells)),
                    size: Self.vectorSize)),
                nominal: ScopeNominalRange(white: Self.unit(of: codes.white),
                                           black: Self.unit(of: codes.black)),
                sequence: ScopeAnalyzer.nextSequence())
        }

        private func histogram(_ index: Int) -> [Int] {
            UnsafeBufferPointer(start: hist + index * 256, count: 256).map(Int.init)
        }

        /// RGBA luma trace: brightness from the density, hue and saturation
        /// from the mean color of the pixels that made it.
        private func coloredTrace(density: [Int32]) -> [UInt8] {
            let colorR = Self.softened(sumR)
            let colorG = Self.softened(sumG)
            let colorB = Self.softened(sumB)
            var colored = [UInt8](repeating: 0, count: Self.cells * 4)
            let yScale = 255.0 / Self.logOf(max(1, density.max() ?? 1))
            for i in 0..<Self.cells {
                let count = density[i]
                guard count > 0 else { continue }
                let brightness = min(255.0, yScale * Self.logOf(count))
                // one reciprocal, not three divisions: this runs once per cell
                // of a 512x512 map and a divide is twenty times a multiply
                let inverse = 1 / Double(count)
                let avgR = Double(colorR[i]) * inverse
                let avgG = Double(colorG[i]) * inverse
                let avgB = Double(colorB[i]) * inverse
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
