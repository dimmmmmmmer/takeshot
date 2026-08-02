import CoreVideo
import Foundation
import Testing

@testable import CaptureCore

/// What the chroma key costs per displayed frame, measured rather than assumed.
///
/// Same shape as `ScopePerformanceTests`, and for the same reasons: the timings
/// are opt-in (`TAKESHOT_BENCH=1 scripts/test.sh --filter ChromaKeyPerformance`)
/// and they assert nothing about wall-clock time, because this suite shares a
/// machine with whatever else is building on it. What they print is the number
/// the budget is argued from. The budget itself is one frame interval — 40 ms
/// at 25 fps — and it is stated in `CapturePipeline.displayBudgetNanos`, which
/// is what the display stage checks a frame's age against before it spends
/// anything on the effect.
///
/// The arithmetic half of that budget is asserted here on every run.
struct ChromaKeyPerformanceTests {
    private static var enabled: Bool {
        ProcessInfo.processInfo.environment["TAKESHOT_BENCH"] != nil
    }

    /// A green screen with a subject on it, at broadcast sizes.
    private func stageFrame(width: Int, height: Int) -> CVPixelBuffer {
        ChromaProbe.frame(screen: ChromaProbe.litCyc,
                          subject: ChromaProbe.spilledEdge,
                          width: width, height: height)
    }

    /// Milliseconds per pass: minimum, median and maximum over `runs`. The
    /// MINIMUM is the number to compare across builds — it is the run that got
    /// a whole core to itself.
    @discardableResult
    private func time(_ label: String, runs: Int = 15,
                      _ body: () -> Void) -> Double {
        for _ in 0..<3 { body() } // warm the context, the pool and the cube
        var samples: [Double] = []
        for _ in 0..<runs {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            samples.append(
                Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        samples.sort()
        print(String(format: "KEYBENCH %@: min %.2f ms  median %.2f ms  max %.2f ms",
                     label, samples[0], samples[runs / 2], samples[runs - 1]))
        return samples[0]
    }

    /// The per-frame cost of the effect, background by background, at the two
    /// sizes this app is pointed at.
    @Test(.enabled(if: ChromaKeyPerformanceTests.enabled))
    func onePassOverABroadcastFrame() {
        let keyer = ChromaKeyer()
        var key = ChromaProbe.magentaKey()
        for (width, height, name) in [(1920, 1080, "1080p"), (3840, 2160, "UHD")] {
            let frame = stageFrame(width: width, height: height)
            for background in ChromaKey.Background.allCases {
                key.background = background
                time("\(name) \(background.rawValue)", runs: width > 2000 ? 9 : 15) {
                    _ = keyer.keyed(frame, key: key)
                }
            }
        }
    }

    /// The rebuild the sliders pay for. It happens on the display queue, once
    /// per changed parameter set, and it is why the lattice is 32³ and not the
    /// 64³ the exposure palettes use.
    @Test(.enabled(if: ChromaKeyPerformanceTests.enabled))
    func rebuildingTheLookupTable() {
        let key = ChromaProbe.magentaKey()
        time("cube 32³ (rebuilt per slider tick)") {
            _ = key.cubeData(matteOnly: false)
        }
        time("cube 64³ (what the palettes cost)", runs: 5) {
            _ = key.cubeData(dimension: 64, matteOnly: false)
        }
    }

    /// The budget the lateness gate measures against, with no stopwatch in it:
    /// one frame interval at the signal's rate, and 25 fps assumed when there
    /// is no signal to ask.
    @Test func theBudgetIsOneFrameInterval() {
        let cases: [(fps: Double, ms: Double)] = [
            (25, 40), (24, 41.67), (30, 33.33), (50, 20), (60, 16.67),
        ]
        for one in cases {
            let nanos = CapturePipeline.displayBudgetNanos(atFrameRate: one.fps)
            #expect(abs(Double(nanos) / 1_000_000 - one.ms) < 0.01,
                    "\(one.fps) fps budgets \(Double(nanos) / 1_000_000) ms")
        }
        for absent in [0.0, -1, .infinity, .nan] {
            #expect(CapturePipeline.displayBudgetNanos(atFrameRate: absent)
                        == 40_000_000)
        }
    }
}
