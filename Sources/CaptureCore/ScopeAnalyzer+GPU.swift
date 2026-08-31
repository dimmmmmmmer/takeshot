import CoreVideo
import Foundation

/// The analyzer's GPU half: the walk that unpacks into the shader's storage,
/// and the accumulator's two ends of the same seam.
///
/// Its own file because both halves outgrew the types they belong to — and
/// because keeping them together is the point: the constants the shader reads
/// are built in `metalParams` from the accumulator's own, and the maps it
/// fills come back through `install` into the accumulator's own buffers, so
/// `finish()` is the code that was already there reading the same numbers.
extension ScopeAnalyzer {
    /// The same walk, UNPACKING only, with the scatter handed to the GPU.
    ///
    /// The split is deliberate and it is where the cost is: reading the frame
    /// is bit-twiddling against three packed layouts with their own stride
    /// rules — hardware facts this project has already got wrong once — and it
    /// is sequential and cheap. The scatter is thirty writes per sample into
    /// four megabytes of maps, and that is the twenty milliseconds.
    ///
    /// nil at any step means the CPU path runs instead: no Metal device, no
    /// shader, no command queue. A machine without a GPU is a real
    /// configuration and a scope that vanished there would be worse than a
    /// slow one.
    static func analyzedOnGPU<Reader: FrameReader>(
        _ reader: Reader, region: ScopeRegion, levels: ScopeWireLevels,
        colorimetry: WireColorimetry) -> ScopeData? {
        guard reader.width > 1, reader.height > 0 else { return nil }
        let window = region.pixels(width: reader.width, height: reader.height)
        // The walk runs INTO the GPU's own storage, which is why `fill` is a
        // closure rather than a returned array: a Swift array here would be
        // 4.4 MB allocated and copied per frame.
        let acc = Accumulator(levels: levels, colorimetry: colorimetry)
        let params = acc.metalParams(
            columns: gridCols, rows: gridRows,
            hasNativeLuma: Reader.carriesNativeLuma,
            hasNativeChroma: Reader.carriesNativeChroma)
        var data: ScopeData?
        let ran = ScopeAnalyzerMetal.accumulate(
            ScopeAnalyzerMetal.Request(
                sampleCount: gridRows * gridCols, params: params,
                linear: acc.linearFloats, waveCells: Accumulator.waveCells),
            fill: { storage in
                for gy in 0..<gridRows {
                    let y = window.y + gy * window.height / gridRows
                    for gx in 0..<gridCols {
                        let sample = reader.sample(
                            x: window.x + gx * window.width / gridCols, y: y)
                        var packed = ScopeAnalyzerMetal.Sample()
                        packed.r = UInt16(clamping: sample.r)
                        packed.g = UInt16(clamping: sample.g)
                        packed.b = UInt16(clamping: sample.b)
                        if let luma = sample.nativeLuma {
                            packed.luma = UInt16(clamping: luma)
                        }
                        if let chroma = sample.nativeChroma {
                            packed.cb = Float(chroma.cb)
                            packed.cr = Float(chroma.cr)
                        }
                        storage[gy * gridCols + gx] = packed
                    }
                }
            },
            consume: { maps in
                acc.install(maps)
                data = acc.finish()
            })
        return ran ? data : nil
    }
}

extension ScopeAnalyzer.Accumulator {
    /// The shader's constants, taken from THIS accumulator.
    ///
    /// Built here and nowhere else: every number in it is one the two
    /// implementations share, and a shader that carried its own copy of the
    /// split unit or the segment cap would be a second place for them to
    /// drift. The grid shape is the caller's, because that is the only
    /// thing about a pass the accumulator does not decide.
    func metalParams(columns: Int, rows: Int,
                     hasNativeLuma: Bool, hasNativeChroma: Bool)
        -> ScopeAnalyzerMetal.Params {
        var params = ScopeAnalyzerMetal.Params()
        params.columns = UInt32(columns)
        params.rows = UInt32(rows)
        params.waveWidth = UInt32(Self.width)
        params.waveHeight = UInt32(Self.height)
        params.vectorSize = UInt32(Self.vectorSize)
        params.cieSize = UInt32(Self.cieSize)
        params.cieSpan = Float(ScopeData.cieSpan)
        params.sampleLevels = UInt32(ScopeAnalyzer.sampleLevels)
        params.maxSpan = Int32(Self.maxSpan)
        params.splitUnit = Self.splitUnit
        params.chromaGain = Float(chromaGain)
        params.lumaR = Float(lumaWeights.r)
        params.lumaG = Float(lumaWeights.g)
        params.lumaB = Float(lumaWeights.b)
        params.m00 = Float(toXYZ.xr)
        params.m01 = Float(toXYZ.xg)
        params.m02 = Float(toXYZ.xb)
        params.m10 = Float(toXYZ.yr)
        params.m11 = Float(toXYZ.yg)
        params.m12 = Float(toXYZ.yb)
        params.m20 = Float(toXYZ.zr)
        params.m21 = Float(toXYZ.zg)
        params.m22 = Float(toXYZ.zb)
        params.hasNativeLuma = hasNativeLuma ? 1 : 0
        params.hasNativeChroma = hasNativeChroma ? 1 : 0
        return params
    }

    /// The linear-light table the shader reads, at the precision it has.
    /// `Double` on this side, `float` on that one — see the note on
    /// precision in `ScopeAnalyzerMetal`.
    var linearFloats: [Float] {
        (0..<ScopeAnalyzer.sampleLevels).map { Float(linear[$0]) }
    }

    /// How many cells one waveform difference array has. `height + 1`
    /// rows, because a segment's END index is one row past its bottom —
    /// which is also the size the GPU buffers have to be, and getting it
    /// wrong there is a write off the end of a buffer rather than a
    /// visible mistake.
    static var waveCells: Int { diffCells }

    /// Adopt maps the GPU filled, in place of this accumulator's own.
    ///
    /// The counts are the same integers the CPU walk would have produced,
    /// so everything downstream — the softening, the log curves, the
    /// coloured trace — is the code that was already there, reading the
    /// same numbers from the same buffers.
    func install(_ maps: ScopeAnalyzerMetal.Maps) {
        func copy(_ source: UnsafeBufferPointer<Int32>,
                  into destination: UnsafeMutablePointer<Int32>,
                  count: Int) {
            precondition(source.count == count,
                         "the GPU returned \(source.count) cells, not \(count)")
            destination.update(from: source.baseAddress!, count: count)
        }
        copy(maps.diffY, into: diffY, count: Self.diffCells)
        copy(maps.diffR, into: diffR, count: Self.diffCells)
        copy(maps.diffG, into: diffG, count: Self.diffCells)
        copy(maps.diffB, into: diffB, count: Self.diffCells)
        copy(maps.sumR, into: sumR, count: Self.diffCells)
        copy(maps.sumG, into: sumG, count: Self.diffCells)
        copy(maps.sumB, into: sumB, count: Self.diffCells)
        copy(maps.hist, into: hist, count: 4 * 256)
        copy(maps.vector, into: vector, count: Self.vectorCells)
        copy(maps.cie, into: cie, count: Self.cieCells)
    }
}
