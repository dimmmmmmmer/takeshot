import Foundation

/// The scope accumulator: one pass over the sampling grid fills the waveform,
/// histogram, vectorscope and chromaticity densities, and `finish()` turns them
/// into a `ScopeData`.
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
        static let cieSize = ScopeData.cieSize
        static let cieCells = cieSize * cieSize
        /// Fixed-point denominator for each axis of a split deposit — the
        /// vectorscope's and the chromaticity chart's alike — chosen so the
        /// four corner weights sum to exactly `splitUnit * splitUnit` with no
        /// division and no rounding loss:
        /// (u−tx)(u−ty) + tx(u−ty) + (u−tx)ty + tx·ty = u² for any tx, ty.
        /// A sixteenth of a cell is about a fifth of a device pixel at the
        /// sizes these maps are drawn at, so nothing is lost by stopping there.
        static let splitUnit: Int32 = 16
        /// What one sample deposits in total, and therefore what `finish()`
        /// divides back out before the brightness curve.
        static let splitWeight = splitUnit * splitUnit

        /// What the wire codes mean, for the nominal range `finish()` publishes
        /// and for the vectorscope's chroma gain.
        private let levels: ScopeWireLevels
        private let chromaGain: Double
        /// What those codes mean as luminance and as colour. Carried through
        /// untouched for every TRACE — the waveform, the parade, the histogram
        /// and the vectorscope do no transfer arithmetic at all, because a
        /// scope plots the codes that arrived, and the transfer is handed on so
        /// the AXIS can be labelled in the units those codes are in. The
        /// chromaticity map is the exception and says why at `addToCIE`.
        private let colorimetry: WireColorimetry
        /// This frame's luma coefficients, off the same derived matrix the
        /// chromaticity chart and the vectorscope's targets read. Held rather
        /// than looked up per sample: this runs 829 k times a frame at 1080p.
        ///
        /// Rec.2020 codes luma with different weights, and a waveform drawn
        /// with 709's on a 2020 signal reads a saturated green too dark and a
        /// saturated blue too bright — an exposure judgement made against the
        /// wrong number, which is the one thing this instrument exists to get
        /// right.
        private let lumaWeights: LinearRGB
        /// This frame's own RGB→XYZ matrix, from its own primaries.
        private let toXYZ: RGBToXYZ
        /// Wire code → linear light, all 1024 of them, built once per frame.
        ///
        /// The reason there is a table at all: linearizing costs a `pow` and
        /// the grid walk takes 276 k samples of three components, so doing it
        /// per sample is 829 k transcendental calls a frame. It is the same
        /// answer `WireDisplayTable` gives for the display half — a transfer
        /// function is a function of the CODE, and there are only 1024 codes.
        private let linear: UnsafeMutablePointer<Double>

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
        /// CIE chromaticity density — the same shape of map as the vectorscope's
        /// and filled the same way.
        private let cie: UnsafeMutablePointer<Int32>
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

        init(levels: ScopeWireLevels = .full,
             colorimetry: WireColorimetry = .sdr) {
            self.levels = levels
            self.colorimetry = colorimetry
            toXYZ = colorimetry.primaries.rgbToXYZ
            lumaWeights = toXYZ.lumaWeights
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
            cie = zeroed(Self.cieCells)
            hist = zeroed(4 * 256)
            linear = Self.linearTable(levels: levels,
                                      transfer: colorimetry.transfer)
        }

        deinit {
            for buffer in [diffY, diffR, diffG, diffB, sumR, sumG, sumB,
                           vector, cie, hist] {
                buffer.deallocate()
            }
            linear.deallocate()
        }

        /// Linear light for every wire code on this frame's levels and
        /// transfer, in units of diffuse white.
        ///
        /// The levels half is what turns a CODE into the 0…1 signal a transfer
        /// function is defined on, and it is the same nominal pair every other
        /// scope's graticule is placed by — so a studio-swing frame's code 64
        /// is signal 0 here exactly as it is 0 % there, and a full-range one's
        /// code 0 is. Getting this wrong is invisible on the chart and moves
        /// every colour on it: a limited-range frame read as full puts black at
        /// signal 0.063, whose 2.4 power is not zero, and every dark pixel then
        /// drifts toward the white point instead of staying where it is.
        private static func linearTable(levels: ScopeWireLevels,
                                        transfer: SignalTransfer)
            -> UnsafeMutablePointer<Double> {
            let codes = levels.nominalCodes
            let span = Double(codes.white - codes.black)
            let table = UnsafeMutablePointer<Double>.allocate(
                capacity: ScopeAnalyzer.sampleLevels)
            for code in 0..<ScopeAnalyzer.sampleLevels {
                let signal = (Double(code) - Double(codes.black)) / span
                table[code] = transfer.linearLight(forSignal: signal)
            }
            return table
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
            // The weights are THIS frame's, from its own primaries — see
            // `lumaWeights`. A YCbCr source passes `nativeLuma`, which the
            // camera already coded with its own matrix, so only the RGB path
            // has a choice to get wrong.
            let luma = nativeLuma
                ?? min(ScopeAnalyzer.sampleLevels - 1,
                       Int((lumaWeights.r * Double(r) + lumaWeights.g * Double(g)
                            + lumaWeights.b * Double(b)).rounded()))
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
            addToCIE(r: r, g: g, b: b)
        }

        /// Vectorscope: full-range BT.709 chroma, ±(scale/2) → ±half-size.
        /// `chromaGain` puts an unexpanded wire frame back on the full-range
        /// scale the graticule targets are positioned on.
        ///
        /// The sample is SPLIT between the four cells around it rather than
        /// dropped whole into the one it falls in — see
        /// `split(into:size:x:y:)`, which the chromaticity chart shares. One
        /// sample always deposits exactly `splitWeight`, and `finish()` divides
        /// it back out, so the brightness curve is the one it always was (see
        /// `toBytesLog(_:unit:)`).
        @inline(__always)
        private func addToVector(r: Int, g: Int, b: Int,
                                 nativeChroma: (cb: Double, cr: Double)?) {
            let raw = nativeChroma
                ?? ScopeAnalyzer.chroma(r: Double(r), g: Double(g),
                                        b: Double(b),
                                        primaries: colorimetry.primaries)
            let cb = raw.cb * chromaGain, cr = raw.cr * chromaGain
            let size = Self.vectorSize
            let span = Double(ScopeAnalyzer.sampleLevels - 1)
            split(into: vector, size: size,
                  x: Double(size) / 2 + cb * Double(size) / span,
                  y: Double(size) / 2 - cr * Double(size) / span)
        }

        /// CIE 1931 chromaticity: where this sample's colour sits on the
        /// diagram, under THIS frame's transfer and THIS frame's primaries.
        ///
        /// The one accumulation in the walk that is not a function of the code
        /// alone, and both halves of that are the point of the scope:
        ///
        /// - **Linear light first.** A chromaticity is a ratio between the
        ///   three linear components, and a wire code is gamma-encoded, so
        ///   computing x and y straight from the codes is wrong for every
        ///   colour that is not neutral — and wrong quietly: the chart still
        ///   looks like a chart. `linear` is the frame's own inverse transfer
        ///   (`SignalTransfer.linearLight`) tabulated over all 1024 codes.
        /// - **The frame's own matrix.** Rec.2020 codes mean different
        ///   chromaticities than Rec.709 codes, which is exactly what an
        ///   operator opens this scope to see. `toXYZ` comes from
        ///   `WireColorimetry.primaries` and is derived from the same four
        ///   chromaticities the graticule draws its triangle from.
        ///
        /// Everything after that is the vectorscope's machinery unchanged: the
        /// same fixed-point split between the four cells around the point, so
        /// the trace has a position finer than the grid, and the same
        /// unit-aware log curve in `finish()`.
        @inline(__always)
        private func addToCIE(r: Int, g: Int, b: Int) {
            guard let point = toXYZ.chromaticity(r: linear[r], g: linear[g],
                                                 b: linear[b]) else { return }
            let unit = ScopeData.cieUnit(point)
            let size = Self.cieSize
            split(into: cie, size: size,
                  x: unit.x * Double(size), y: unit.y * Double(size))
        }

        /// Deposit one sample at a fractional position on a square map, split
        /// between the four cells around it by how close it lands to each.
        ///
        /// Shared by the vectorscope and the chromaticity chart because they
        /// have the identical problem: a 256-cell map drawn across three or
        /// four times that in device pixels, one sample per position and no
        /// segments to fill, so a whole-cell deposit quantises every trace to
        /// the cell grid and the separable blur that follows turns that
        /// staircase into haze rather than into detail. Splitting gives the
        /// trace a position finer than a cell, which is what "higher
        /// resolution" on a plot like this actually means: the same samples,
        /// plotted where they really are.
        @inline(__always)
        private func split(into map: UnsafeMutablePointer<Int32>, size: Int,
                           x: Double, y: Double) {
            // Cell centres sit at i + 0.5, so the neighbours of a point at `x`
            // are the cells either side of `x - 0.5`.
            let fx = x - 0.5, fy = y - 0.5
            let ix = Int(fx.rounded(.down)), iy = Int(fy.rounded(.down))
            let tx = Int32((fx - fx.rounded(.down)) * Double(Self.splitUnit))
            let ty = Int32((fy - fy.rounded(.down)) * Double(Self.splitUnit))
            let unit = Self.splitUnit
            deposit(map, size, ix, iy, (unit - tx) * (unit - ty))
            deposit(map, size, ix + 1, iy, tx * (unit - ty))
            deposit(map, size, ix, iy + 1, (unit - tx) * ty)
            deposit(map, size, ix + 1, iy + 1, tx * ty)
        }

        /// One corner of the split. A sample at the very edge of the map has
        /// neighbours outside it: their share is folded onto the edge cell
        /// rather than dropped, so a sample always deposits its whole weight
        /// and the totals stay a count of samples.
        @inline(__always)
        private func deposit(_ map: UnsafeMutablePointer<Int32>, _ size: Int,
                             _ x: Int, _ y: Int, _ weight: Int32) {
            guard weight != 0 else { return }
            let cx = min(size - 1, max(0, x)), cy = min(size - 1, max(0, y))
            map[cy * size + cx] += weight
        }

        func finish() -> ScopeData {
            let softY = DensityMap.softened(diffY)
            // colored luma trace: brightness from the softened density (log),
            // chroma from the blurred means so color follows the soft edge
            let colored = coloredTrace(density: softY)
            let codes = levels.nominalCodes
            return ScopeData(
                waveformY: DensityMap.toBytesLog(softY),
                waveformR: DensityMap.toBytesLog(DensityMap.softened(diffR)),
                waveformG: DensityMap.toBytesLog(DensityMap.softened(diffG)),
                waveformB: DensityMap.toBytesLog(DensityMap.softened(diffB)),
                waveformYColor: colored,
                histR: histogram(0), histG: histogram(1),
                histB: histogram(2), histY: histogram(3),
                // the vectorscope is softened in both directions: one sample per
                // cell and no segments to fill left it a field of hard dots
                // that read as a low-resolution scope rather than as a density
                vector: DensityMap.toBytesLog(DensityMap.blurred(
                    Array(UnsafeBufferPointer(start: vector,
                                              count: Self.vectorCells)),
                    size: Self.vectorSize),
                    unit: Self.splitWeight),
                // the chromaticity map is softened and scaled exactly like the
                // vectorscope's, for exactly the same reasons — one sample per
                // position, real gaps in both directions, and counts that are
                // `splitWeight` per sample rather than 1
                cie: DensityMap.toBytesLog(DensityMap.blurred(
                    Array(UnsafeBufferPointer(start: cie,
                                              count: Self.cieCells)),
                    size: Self.cieSize),
                    unit: Self.splitWeight),
                nominal: ScopeNominalRange(white: Self.unit(of: codes.white),
                                           black: Self.unit(of: codes.black)),
                transfer: colorimetry.transfer,
                primaries: colorimetry.primaries,
                sequence: ScopeAnalyzer.nextSequence())
        }

        private func histogram(_ index: Int) -> [Int] {
            UnsafeBufferPointer(start: hist + index * 256, count: 256).map(Int.init)
        }

        /// RGBA luma trace: brightness from the density, hue and saturation
        /// from the mean color of the pixels that made it.
        private func coloredTrace(density: [Int32]) -> [UInt8] {
            let colorR = DensityMap.softened(sumR)
            let colorG = DensityMap.softened(sumG)
            let colorB = DensityMap.softened(sumB)
            var colored = [UInt8](repeating: 0, count: Self.cells * 4)
            let yScale = 255.0 / DensityMap.logOf(max(1, density.max() ?? 1))
            for i in 0..<Self.cells {
                let count = density[i]
                guard count > 0 else { continue }
                let brightness = min(255.0, yScale * DensityMap.logOf(count))
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
