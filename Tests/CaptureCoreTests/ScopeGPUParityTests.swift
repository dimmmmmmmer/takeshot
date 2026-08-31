import CoreVideo
import Testing

@testable import CaptureCore

/// The GPU path measures the same signal the CPU path does.
///
/// This is the test the whole change stands on. The scopes are an INSTRUMENT:
/// an operator judges exposure and gamut by them, so a second implementation is
/// only allowed to exist if it can be shown to agree with the first. The CPU
/// walk stays the reference and this compares against it.
///
/// **Where exact agreement is possible it is required.** The waveform segments
/// and the histogram are integer arithmetic on both sides — the same row
/// function, the same span cap, the same bins — so they are asserted byte for
/// byte.
///
/// **Where it is not, the difference is measured rather than waved past.**
/// Metal has no `double`: the luma weights, the chroma and the chromaticity are
/// `float` on the GPU and `Double` on the CPU, so a sample sitting on a
/// rounding boundary can land one code, or one cell, either side of where the
/// CPU puts it. What is asserted for those is the RENDERED bytes, because that
/// is what an operator looks at, and within a tolerance stated here rather than
/// discovered later.
struct ScopeGPUParityTests {
    /// One wire pixel, as the fixture writes it.
    struct WirePixel {
        var r: Int
        var g: Int
        var b: Int
    }

    private func wire(_ make: (Int, Int) -> WirePixel,
                      width: Int = 512, height: Int = 288) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            TenBitConverter.r210,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                            &pb)
        let buffer = try #require(pb)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer))
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            let line = base.advanced(by: y * rowBytes)
                .assumingMemoryBound(to: UInt32.self)
            for x in 0..<width {
                let c = make(x, y)
                line[x] = ((UInt32(c.r) << 20) | (UInt32(c.g) << 10)
                    | UInt32(c.b)).bigEndian
            }
        }
        return buffer
    }

    /// Both paths, on the same frame. nil when this machine has no GPU — the
    /// test then says so rather than passing silently.
    private func both(_ buffer: CVPixelBuffer) throws
        -> (cpu: ScopeData, gpu: ScopeData) {
        try #require(ScopeAnalyzerMetal.isAvailable,
                     "no GPU on this machine: \(ScopeAnalyzerMetal.unavailableReason ?? "")")
        ScopeAnalyzerMetal.isEnabled = true
        defer { ScopeAnalyzerMetal.isEnabled = false }
        let gpu = try #require(ScopeAnalyzer.analyze(buffer))
        ScopeAnalyzerMetal.isEnabled = false
        let cpu = try #require(ScopeAnalyzer.analyze(buffer))
        return (cpu, gpu)
    }

    private func maxDelta(_ a: [UInt8], _ b: [UInt8]) -> Int {
        guard a.count == b.count else { return .max }
        return zip(a, b).map { abs(Int($0) - Int($1)) }.max() ?? 0
    }

    /// How the two differ, in one line.
    ///
    /// **Never `#expect(a == b)` on these.** A waveform is 1024 x 512 bytes and
    /// a failed equality builds a failure message out of both of them: the
    /// first version of this suite produced a 3 MB log and spent thirty-three
    /// minutes at 100 % CPU rendering it, which reads exactly like a hung GPU
    /// and is what sent the first diagnosis down the wrong path.
    private func summary(_ a: [UInt8], _ b: [UInt8]) -> String {
        guard a.count == b.count else { return "\(a.count) cells against \(b.count)" }
        let differing = zip(a, b).filter { $0 != $1 }.count
        let worst = maxDelta(a, b)
        let first = a.indices.first { a[$0] != b[$0] }
        return "\(differing) of \(a.count) cells differ, worst by \(worst)"
            + (first.map { ", first at \($0): \(a[$0]) vs \(b[$0])" } ?? "")
    }

    /// A picture with structure in both axes — a gradient across and a ramp
    /// down — so every column has a different span and the segment arithmetic
    /// is actually exercised rather than being one flat row.
    private func structured() throws -> CVPixelBuffer {
        try wire { x, y in
            WirePixel(r: 64 + (x * 800 / 512), g: 64 + (y * 800 / 288),
                      b: 64 + ((x + y) % 800))
        }
    }

    /// The histogram is integer arithmetic on both sides. Exactly equal.
    @Test func theHistogramsAreIdentical() throws {
        let (cpu, gpu) = try both(try structured())
        #expect(gpu.histR.elementsEqual(cpu.histR), "the red histogram differs")
        #expect(gpu.histG.elementsEqual(cpu.histG), "the green histogram differs")
        #expect(gpu.histB.elementsEqual(cpu.histB), "the blue histogram differs")
        // Luma goes through the weights, which are float on one side — so this
        // one is allowed to differ, and by how much is worth knowing.
        let lumaDelta = zip(gpu.histY, cpu.histY)
            .map { abs($0 - $1) }.max() ?? 0
        #expect(lumaDelta <= 2,
                "the luma histogram differs by \(lumaDelta) samples in a bin")
    }

    /// The RGB waveforms take no float at all — same row function, same span
    /// cap, same difference arrays.
    @Test func theRGBWaveformsAreIdentical() throws {
        let (cpu, gpu) = try both(try structured())
        #expect(maxDelta(gpu.waveformR, cpu.waveformR) == 0,
                "the red waveform: \(summary(gpu.waveformR, cpu.waveformR))")
        #expect(maxDelta(gpu.waveformG, cpu.waveformG) == 0,
                "the green waveform: \(summary(gpu.waveformG, cpu.waveformG))")
        #expect(maxDelta(gpu.waveformB, cpu.waveformB) == 0,
                "the blue waveform: \(summary(gpu.waveformB, cpu.waveformB))")
    }

    /// The luma trace and the two scatter maps go through float. What is
    /// asserted is the picture, within a stated tolerance.
    @Test func theFloatMapsAgreeWithinOneCode() throws {
        let (cpu, gpu) = try both(try structured())
        let maps: [(name: String, pair: (gpu: [UInt8], cpu: [UInt8]))] = [
            ("luma", (gpu.waveformY, cpu.waveformY)),
            ("vector", (gpu.vector, cpu.vector)),
            ("cie", (gpu.cie, cpu.cie))]
        for (name, pair) in maps {
            let (a, b) = pair
            let delta = maxDelta(a, b)
            #expect(delta <= 2,
                    """
                    the \(name) map differs by \(delta) of 255 — more than a \
                    rounding boundary can explain
                    """)
        }
    }

    /// A flat frame is the case where a disagreement would be loudest: every
    /// sample lands on the same code, so any float wobble shows as a whole
    /// column moving rather than as a scattered sample.
    @Test func aFlatFrameIsIdenticalEverywhere() throws {
        let (cpu, gpu) = try both(try wire { _, _ in WirePixel(r: 500, g: 400, b: 300) })
        #expect(gpu.waveformY == cpu.waveformY, "a flat frame's luma differs")
        #expect(gpu.waveformR == cpu.waveformR)
        #expect(gpu.histY == cpu.histY)
        #expect(maxDelta(gpu.vector, cpu.vector) <= 2)
        #expect(maxDelta(gpu.cie, cpu.cie) <= 2)
    }
}
