import Foundation

/// The accumulation shader, as source.
///
/// Compiled at runtime with `device.makeLibrary(source:)` rather than built
/// into a `.metallib`. SwiftPM has no Metal build step without a plugin, and
/// this project is SwiftPM-only with no Xcode on the machine — a runtime
/// compile costs tens of milliseconds once per process and keeps the shader in
/// the same module as the CPU implementation it has to agree with, where the
/// two can be read side by side.
///
/// **Every constant here is passed in, not written twice.** The map sizes, the
/// split unit, the span cap and the sample scale all arrive in `Params` from
/// the Swift side, so the shader cannot come to disagree with
/// `ScopeAnalyzer.Accumulator` about a number both of them use — which is the
/// failure a second implementation of anything invites.
enum ScopeKernel {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Params {
        uint  columns;        // grid columns == waveform map width
        uint  rows;           // grid rows walked per column
        uint  waveWidth;
        uint  waveHeight;
        uint  vectorSize;
        uint  cieSize;
        float cieSpan;      // the chart's window on x and y
        uint  sampleLevels;   // 1024
        int   maxSpan;        // segment cap, sampleLevels / 8
        int   splitUnit;      // 16
        float chromaGain;
        float lumaR, lumaG, lumaB;
        // RGB -> XYZ, row major, for the chromaticity chart
        float m00, m01, m02, m10, m11, m12, m20, m21, m22;
        uint  hasNativeLuma;   // 1 when the source carried its own luma
        uint  hasNativeChroma; // 1 when the source carried its own Cb/Cr
    };

    /// One sample as the CPU walk unpacked it. `luma` and `cb`/`cr` are only
    /// read when the flags say the source carried them.
    struct Sample {
        ushort r, g, b, luma;
        float  cb, cr;
    };

    /// Scope row for a 10-bit code: row 0 is the top of the trace. The same
    /// integer arithmetic as `Accumulator.row(for:)`, deliberately — a float
    /// here would put a sample on the other side of a row boundary.
    static inline int scope_row(int value, uint height, uint levels) {
        int scaled = (int)((uint)value * height / levels);
        int capped = min((int)height - 1, scaled);
        return (int)height - 1 - capped;
    }

    /// One corner of a bilinear split, folded onto the edge when it falls off.
    static inline void deposit(device atomic_int *map, uint size,
                               int x, int y, int weight) {
        if (weight == 0) { return; }
        int cx = clamp(x, 0, (int)size - 1);
        int cy = clamp(y, 0, (int)size - 1);
        atomic_fetch_add_explicit(&map[cy * size + cx], weight,
                                  memory_order_relaxed);
    }

    /// The sample's luma: the source's own when it carried one, this frame's
    /// weights otherwise. Computed for a sample AND for its neighbour, which
    /// is why it is a function.
    static inline int sample_luma(Sample s, constant Params &p) {
        if (p.hasNativeLuma != 0) { return (int)s.luma; }
        float y = p.lumaR * (float)s.r + p.lumaG * (float)s.g
                + p.lumaB * (float)s.b;
        return min((int)p.sampleLevels - 1, (int)round(y));
    }

    /// One counted write into a shared map.
    static inline void add(device atomic_int *map, int index, int value) {
        atomic_fetch_add_explicit(&map[index], value, memory_order_relaxed);
    }

    /// A sample split between the four cells around it, depositing exactly
    /// `splitUnit * splitUnit` however it lands.
    static inline void split(device atomic_int *map, uint size,
                             float x, float y, int unit) {
        float fx = x - 0.5f, fy = y - 0.5f;
        float bx = floor(fx), by = floor(fy);
        int ix = (int)bx, iy = (int)by;
        int tx = (int)((fx - bx) * (float)unit);
        int ty = (int)((fy - by) * (float)unit);
        deposit(map, size, ix,     iy,     (unit - tx) * (unit - ty));
        deposit(map, size, ix + 1, iy,     tx * (unit - ty));
        deposit(map, size, ix,     iy + 1, (unit - tx) * ty);
        deposit(map, size, ix + 1, iy + 1, tx * ty);
    }

    /// One thread per SAMPLE, and no sequential chain anywhere.
    ///
    /// **The segment depends on the sample BESIDE this one, not on an
    /// accumulated state** — `Accumulator.add` joins each sample to the
    /// previous one in the same scanline and resets at `col == 0`. That
    /// neighbour is `samples[gid - 1]`, readable directly, so nothing has to be
    /// walked in order and every one of the 276 480 samples is its own thread.
    ///
    /// The first shape here was a thread per COLUMN, which joined each sample
    /// to the one ABOVE it instead: the histograms came out identical and the
    /// waveform did not, which is exactly how it was caught. The second was a
    /// thread per row — correct, but 270 threads is most of a GPU standing
    /// idle.
    ///
    /// Every map is atomic, because two samples anywhere in the frame can land
    /// in the same cell of the same column.
    kernel void scope_accumulate(
        device const Sample   *samples   [[buffer(0)]],
        device const float    *linearLUT [[buffer(1)]],
        device atomic_int     *diffY     [[buffer(2)]],
        device atomic_int     *diffR     [[buffer(3)]],
        device atomic_int     *diffG     [[buffer(4)]],
        device atomic_int     *diffB     [[buffer(5)]],
        device atomic_int     *sumR      [[buffer(6)]],
        device atomic_int     *sumG      [[buffer(7)]],
        device atomic_int     *sumB      [[buffer(8)]],
        device atomic_int     *hist      [[buffer(9)]],
        device atomic_int     *vectorMap [[buffer(10)]],
        device atomic_int     *cieMap    [[buffer(11)]],
        constant Params       &p         [[buffer(12)]],
        uint gid [[thread_position_in_grid]])
    {
        if (gid >= p.rows * p.columns) { return; }
        uint col = gid % p.columns;

        Sample s = samples[gid];
        int r = (int)s.r, g = (int)s.g, b = (int)s.b;
        int luma = sample_luma(s, p);

        // 256 bins over the 10-bit scale, four channels in one buffer.
        add(hist, r >> 2, 1);
        add(hist, 256 + (g >> 2), 1);
        add(hist, 512 + (b >> 2), 1);
        add(hist, 768 + (luma >> 2), 1);

        // The neighbour, or "no neighbour" at the start of a scanline.
        bool joined = col > 0;
        Sample q = joined ? samples[gid - 1] : s;
        int prevLuma = joined ? sample_luma(q, p) : -1;
        int vals[4] = { luma, r, g, b };
        int prevs[4] = { prevLuma,
                         joined ? (int)q.r : -1,
                         joined ? (int)q.g : -1,
                         joined ? (int)q.b : -1 };
        int tops[4], ends[4];
        for (int k = 0; k < 4; ++k) {
            int v = vals[k], pv = prevs[k];
            int from = (pv < 0) ? v : min(max(pv, v - p.maxSpan), v + p.maxSpan);
            tops[k] = scope_row(max(v, from), p.waveHeight, p.sampleLevels)
                    * (int)p.waveWidth + (int)col;
            ends[k] = (scope_row(min(v, from), p.waveHeight, p.sampleLevels) + 1)
                    * (int)p.waveWidth + (int)col;
        }
        add(diffY, tops[0], 1); add(diffY, ends[0], -1);
        add(diffR, tops[1], 1); add(diffR, ends[1], -1);
        add(diffG, tops[2], 1); add(diffG, ends[2], -1);
        add(diffB, tops[3], 1); add(diffB, ends[3], -1);
        // The colour sums ride the LUMA segment: the coloured trace takes its
        // hue from the pixels that made each cell of that trace.
        add(sumR, tops[0], r); add(sumR, ends[0], -r);
        add(sumG, tops[0], g); add(sumG, ends[0], -g);
        add(sumB, tops[0], b); add(sumB, ends[0], -b);

        // Vectorscope.
        float cb, cr;
        if (p.hasNativeChroma != 0) {
            cb = s.cb; cr = s.cr;
        } else {
            float yy = p.lumaR * (float)r + p.lumaG * (float)g
                     + p.lumaB * (float)b;
            cb = ((float)b - yy) / (2.0f * (1.0f - p.lumaB));
            cr = ((float)r - yy) / (2.0f * (1.0f - p.lumaR));
        }
        cb *= p.chromaGain; cr *= p.chromaGain;
        float span = (float)(p.sampleLevels - 1);
        // NOT `half`: that is a built-in type in Metal.
        float centre = (float)p.vectorSize / 2.0f;
        split(vectorMap, p.vectorSize,
              centre + cb * (float)p.vectorSize / span,
              centre - cr * (float)p.vectorSize / span,
              p.splitUnit);

        // Chromaticity, in LINEAR light: the frame's own inverse transfer,
        // tabulated over all 1024 codes on the Swift side.
        float lr = linearLUT[r], lg = linearLUT[g], lb = linearLUT[b];
        float X = p.m00 * lr + p.m01 * lg + p.m02 * lb;
        float Y = p.m10 * lr + p.m11 * lg + p.m12 * lb;
        float Z = p.m20 * lr + p.m21 * lg + p.m22 * lb;
        float total = X + Y + Z;
        if (total > 0.0f) {
            // The same two lines as `ScopeData.cieUnit` and the `split` call
            // beside it: the chart's window is `cieSpan` wide, and row 0 is the
            // TOP, which is where the `1 -` comes from.
            float cx = (X / total) / p.cieSpan;
            float cy = 1.0f - (Y / total) / p.cieSpan;
            split(cieMap, p.cieSize, cx * (float)p.cieSize,
                  cy * (float)p.cieSize, p.splitUnit);
        }
    }
    """
}
