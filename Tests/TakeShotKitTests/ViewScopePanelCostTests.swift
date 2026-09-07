import AppKit
import CaptureCore
import CoreVideo
import Foundation
import SwiftUI
import Testing

@testable import TakeShotKit

/// **What one scope publish costs the window.**
///
/// The analyzer's half of this has been measured twice and is settled: 7.0 ms
/// a pass in an 80 ms stride, 20 of 20 passes delivered, and the same number at
/// UHD as at 1080p because `finish` works on 512×512 maps whatever came in
/// (`ScopePerformanceTests`). What was never measured is the other half — what
/// happens on the MAIN THREAD when that pass arrives: the panel's body re-runs,
/// every visible box rebuilds its trace image and redraws its graticule
/// `Canvas`, twelve and a half times a second, on the thread that also has to
/// lay out the rest of the window.
///
/// The owner reported the scopes lagging and the answer was a measurement of
/// the analyzer, which is not what an operator is looking at. This is the
/// instrument for the half that was missing.
///
/// Opt-in behind `TAKESHOT_BENCH=1`, reports rather than asserts, and worth
/// nothing in a debug build — the accumulator alone is 80× its release cost
/// there. Run it as
/// `TAKESHOT_BENCH=1 ./scripts/test.sh -c release --scratch-path .build-release
/// --filter ViewScopePanelCostTests`.
@MainActor
struct ViewScopePanelCostTests {
    nonisolated static var enabled: Bool {
        ProcessInfo.processInfo.environment["TAKESHOT_BENCH"] == "1"
    }

    /// **Every scope draws through a `Canvas`.**
    ///
    /// The rule the measurements above bought, asserted on the source because
    /// milliseconds cannot be: a scope box built out of child views — a shape
    /// per channel, a `Circle` per ring, a shadowed `Text` per label — is laid
    /// out and drawn again on every publish, twelve and a half times a second,
    /// on the thread that also lays out the window. Measured on this machine,
    /// release, one box at 440x300:
    ///
    /// | box       | view tree | one Canvas |
    /// |-----------|-----------|------------|
    /// | histogram | 8.49 ms   | 3.85 ms    |
    /// | vector    | 7.19 ms   | 2.18 ms    |
    ///
    /// A four-up grid went from 20.3 ms a publish to 10.7 — from missing a
    /// 60 Hz frame on every scope update to fitting inside one. That is the
    /// owner's "скопы страшно лагают", and it was never the analyzer: that
    /// half is 7.0 ms in an 80 ms stride and delivers every pass it is offered
    /// (`ScopePerformanceTests`).
    @Test func everyScopeSurfaceDrawsThroughACanvas() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TakeShotKit")
        for name in ["ScopeGraticule", "ScopeCodeAxis", "ScopeTraces",
                     "VectorscopeGraticule"] {
            let code = try String(
                contentsOf: root.appendingPathComponent("\(name).swift"),
                encoding: .utf8)
            #expect(code.contains("Canvas(opaque: false"),
                    Comment(rawValue: "\(name) draws with a view tree again — "
                        + "see the measurements on this test"))
        }
    }

    /// A frame with structure in it — a flat one produces a single-column trace
    /// and an image build that is not representative. Deterministic: a fixed
    /// linear congruential walk, so two runs measure the same picture.
    private func noise(width: Int, height: Int, seed: UInt32) -> CVPixelBuffer {
        let buffer = MediaFixtures.pixelBuffer(level: 0, width: width,
                                               height: height)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return buffer }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var state = seed | 1
        for y in 0..<height {
            let row = bytes + y * rowBytes
            for x in 0..<width {
                state = state &* 1_664_525 &+ 1_013_904_223
                let value = UInt8((state >> 16) & 0xFF)
                row[x * 4] = value
                row[x * 4 + 1] = value &+ UInt8(truncatingIfNeeded: x)
                row[x * 4 + 2] = value &+ UInt8(truncatingIfNeeded: y)
                row[x * 4 + 3] = 255
            }
        }
        return buffer
    }

    private func analysed(seed: UInt32) throws -> ScopeData {
        try #require(ScopeAnalyzer.analyze(noise(width: 1920, height: 1080,
                                                 seed: seed),
                                           wireLevels: .full),
                     "the analyzer refused the bench frame")
    }

    /// One render of a hosted view, forced all the way to pixels — a layout
    /// pass alone would miss the `Canvas` and the image compositing, which is
    /// where the drawing actually happens.
    private func renderMs(_ host: NSHostingView<AnyView>) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        host.layoutSubtreeIfNeeded()
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
        }
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    /// **The number that was missing.** One scope box, redrawn with a new
    /// analysis each time, at the size one occupies in a four-up grid.
    @Test(.enabled(if: ViewScopePanelCostTests.enabled))
    func whatARepublishCostsOneScopeBox() async throws {
        let size = CGSize(width: 440, height: 300)
        var frames: [ScopeData] = []
        for seed in UInt32(1)...UInt32(12) { frames.append(try analysed(seed: seed)) }

        for (name, make) in Self.boxes {
            var samples: [Double] = []
            for data in frames {
                let host = NSHostingView(rootView: AnyView(make(data)))
                host.frame = CGRect(origin: .zero, size: size)
                _ = renderMs(host) // warm this data's image cache
                samples.append(renderMs(host))
            }
            samples.sort()
            print(String(
                format: "PANELBENCH %@ redraw: min %.2f ms  median %.2f ms  max %.2f ms",
                name, samples[0], samples[samples.count / 2],
                samples[samples.count - 1]))
        }
    }

    /// The same boxes with the data UNCHANGED — what a republish costs when the
    /// image cache hits, which separates the CGImage build from the drawing.
    @Test(.enabled(if: ViewScopePanelCostTests.enabled))
    func whatARedrawCostsWithTheImageAlreadyBuilt() async throws {
        let size = CGSize(width: 440, height: 300)
        let data = try analysed(seed: 7)
        for (name, make) in Self.boxes {
            let host = NSHostingView(rootView: AnyView(make(data)))
            host.frame = CGRect(origin: .zero, size: size)
            for _ in 0..<3 { _ = renderMs(host) }
            var samples: [Double] = []
            for _ in 0..<12 { samples.append(renderMs(host)) }
            samples.sort()
            print(String(
                format: "PANELBENCH %@ cached: min %.2f ms  median %.2f ms  max %.2f ms",
                name, samples[0], samples[samples.count / 2],
                samples[samples.count - 1]))
        }
    }

    /// The graticule on its own, which does not depend on the frame at all —
    /// if it is a large share of a box, it is being redrawn for nothing twelve
    /// and a half times a second.
    @Test(.enabled(if: ViewScopePanelCostTests.enabled))
    func whatTheGraticuleCostsOnItsOwn() async throws {
        let size = CGSize(width: 440, height: 300)
        let host = NSHostingView(rootView: AnyView(
            ScopeLevelGraticule(nominal: .full)))
        host.frame = CGRect(origin: .zero, size: size)
        for _ in 0..<3 { _ = renderMs(host) }
        var samples: [Double] = []
        for _ in 0..<12 { samples.append(renderMs(host)) }
        samples.sort()
        print(String(
            format: "PANELBENCH graticule alone: min %.2f ms  median %.2f ms  max %.2f ms",
            samples[0], samples[samples.count / 2], samples[samples.count - 1]))
    }

    /// The four boxes an operator has open at once, by name.
    private static let boxes: [(String, (ScopeData) -> AnyView)] = [
        ("waveform", { AnyView(WaveformView(data: $0, channel: "y")) }),
        ("parade", { AnyView(ParadeView(data: $0)) }),
        ("histogram", { AnyView(HistogramView(data: $0, channel: "rgb")) }),
        ("vector", { AnyView(VectorscopeView(data: $0)) }),
    ]
}
