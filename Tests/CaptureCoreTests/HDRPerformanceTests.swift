import CoreVideo
import Foundation
import Testing

@testable import CaptureCore

/// What HDR costs the per-frame path, measured rather than argued.
///
/// The claim the design makes is that it costs nothing: an HDR signal reaches
/// the monitor through the same `WireDisplayTable` an SDR one does, so the
/// converters do the same one lookup per component they always did — only the
/// contents of the table differ. Everything HDR adds outside that table is a
/// comparison: one against the frame's reported colorimetry in the levels
/// stage, one inside each converter's setter, and one attachment lookup in the
/// preview layer.
///
/// Opt-in (`TAKESHOT_BENCH=1 scripts/test.sh --filter HDRPerformance`) and it
/// asserts no wall-clock threshold, for the same reason `ScopePerformanceTests`
/// does not: this suite shares a machine with whatever else is building on it.
/// What it prints is the number the claim is argued from. The one thing it DOES
/// assert is free of the clock — that an HDR pass and an SDR pass do the same
/// amount of work, i.e. that the table is the only difference.
struct HDRPerformanceTests {
    private static var enabled: Bool {
        ProcessInfo.processInfo.environment["TAKESHOT_BENCH"] != nil
    }

    private static let width = 1920
    private static let height = 1080

    private func wire() throws -> CVPixelBuffer {
        try V210Fixtures.makeGrey(width: Self.width,
                                  height: Self.height) { x, y in
            64 + ((x * 7 + y * 13) % 877)
        }
    }

    private func elapsed(_ passes: Int, _ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<passes { body() }
        let end = DispatchTime.now().uptimeNanoseconds
        return Double(end - start) / Double(passes) / 1_000_000
    }

    @Test(.enabled(if: enabled, "set TAKESHOT_BENCH=1"))
    func theSplitCostsTheSameUnderHDR() throws {
        let source = try wire()
        let sdr = TenBitYUVConverter()
        sdr.setLevels(.limited)
        let hdr = TenBitYUVConverter()
        hdr.setLevels(.limited)
        hdr.setColorimetry(WireColorimetry(transfer: .pq, primaries: .rec2020))
        // warm the pools
        _ = sdr.convert(source)
        _ = hdr.convert(source)
        let sdrMs = elapsed(30) { _ = sdr.convert(source) }
        let hdrMs = elapsed(30) { _ = hdr.convert(source) }
        print("v210 1080p split: SDR \(String(format: "%.2f", sdrMs)) ms, "
            + "PQ \(String(format: "%.2f", hdrMs)) ms")
    }

    /// The comparison the levels stage makes on every single frame, whether or
    /// not the signal is HDR. Reported per MILLION frames, because per frame it
    /// is below the timer's resolution — which is the point.
    @Test(.enabled(if: enabled, "set TAKESHOT_BENCH=1"))
    func thePerFrameComparisonIsBelowMeasurement() {
        let root = FileManager.default.temporaryDirectory
        var settings = CaptureSettings()
        settings.capture.destinationPath = root.path
        let pipeline = CapturePipeline(
            config: .init(settings: settings, takeNumber: 1))
        let millionMs = elapsed(1) {
            for _ in 0..<1_000_000 { pipeline.adoptColorimetry(.sdr) }
        }
        print("adoptColorimetry: \(String(format: "%.2f", millionMs)) ms "
            + "per 1 000 000 frames")
    }

    /// The clock-free half, and the one that is always run: an HDR table and an
    /// SDR table are the same shape, so nothing downstream of them can be doing
    /// more work. If this ever stops holding, the "HDR is free" claim above has
    /// stopped holding with it.
    @Test func theHDRTableIsTheSameShapeAsTheSDRTable() {
        for bits in [10, 12] {
            let sdr = WireDisplayTable.table(levels: .limited, bits: bits,
                                             transfer: .sdr)
            let pq = WireDisplayTable.table(levels: .limited, bits: bits,
                                            transfer: .pq)
            #expect(sdr.count == pq.count, "\(bits)-bit")
            #expect(MemoryLayout<UInt16>.stride * sdr.count
                == MemoryLayout<UInt16>.stride * pq.count)
        }
    }
}
