import Foundation

extension ScopeAnalyzer {
    /// The arithmetic that turns a filled density map into the bytes a scope
    /// view draws: the trace maps' integrate-and-soften sweep, the square maps'
    /// separable blur, and the log brightness curve all three go through.
    ///
    /// Split out of `Accumulator` for the same reason `Accumulator` was split
    /// out of `ScopeAnalyzer`: this half is about how a map is FINISHED and the
    /// other half is about what fills it, and with five scopes filling maps the
    /// class had grown past the point where the two were still legible next to
    /// each other. Nothing here holds state — every function is a pure
    /// transformation of counts.
    enum DensityMap {
        static let width = ScopeData.waveWidth
        static let height = ScopeData.waveHeight
        static let cells = width * height

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
        static func softened(_ diff: UnsafeMutablePointer<Int32>) -> [Int32] {
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

        /// Separable 1-2-1 blur over a square density map — the vectorscope's
        /// and the chromaticity chart's.
        ///
        /// The trace maps do NOT go through this. They have one integration
        /// sweep that carries their vertical softening, and they need no
        /// horizontal one (see `softened`). The square maps are the opposite
        /// case: one sample per position, no segments, real gaps between the
        /// hits in both directions — so they get the full separable blur.
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
        /// 4); the square maps' few hottest cells fall through to `log`.
        private static let logTable: [Double] =
            (0...8192).map { Foundation.log(Double($0) + 1) }

        @inline(__always)
        static func logOf(_ count: Int32) -> Double {
            let index = Int(count)
            return index <= 8192 ? logTable[index]
                : Foundation.log(Double(index) + 1)
        }

        /// Adaptive log curve, for the waveforms, the vectorscope and the
        /// chromaticity chart alike: single hits stay visible and dense areas
        /// keep their gradation, where a fixed gain either clips into a flat
        /// blob or hides the low densities.
        static func toBytesLog(_ counts: [Int32], unit: Int32 = 1) -> [UInt8] {
            let peak = max(unit, counts.max() ?? unit)
            let scale = 255.0 / logOf(peak, unit: unit)
            var out = [UInt8](repeating: 0, count: counts.count)
            counts.withUnsafeBufferPointer { src in
                out.withUnsafeMutableBufferPointer { dst in
                    for i in 0..<src.count where src[i] != 0 {
                        dst[i] = UInt8(min(255.0,
                                           scale * logOf(src[i], unit: unit)))
                    }
                }
            }
            return out
        }

        /// `log(count/unit + 1)` — the density in SAMPLES, whatever fixed-point
        /// unit the map counts in.
        ///
        /// The vectorscope and the chromaticity chart split a sample between
        /// four cells, so their counts are `Accumulator.splitWeight` per sample
        /// rather than 1. Feeding those straight to the curve would not merely
        /// rescale it: the log's shape changes with the scale, and an isolated
        /// stray sample would have gone from about 23 of 255 to about 108 — a
        /// noise floor lit up by arithmetic nobody chose.
        /// `log(c/u + 1) = log(c + u) − log(u)` keeps the exact curve the map
        /// always had, and keeps the integer table for the common case.
        @inline(__always)
        static func logOf(_ count: Int32, unit: Int32) -> Double {
            guard unit != 1 else { return logOf(count) }
            return logOf(count + unit) - Foundation.log(Double(unit))
        }
    }
}
