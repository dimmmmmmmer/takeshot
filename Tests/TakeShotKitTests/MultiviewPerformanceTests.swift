import AppKit
import CoreImage
import CoreVideo
import Foundation
import Testing

@testable import TakeShotKit

/// What one phone tile costs: the encode pass, and the bytes it puts on the set
/// network.
///
/// The timings are opt-in, like the keyer's, the scopes' and the NDI mirror's:
///
///     TAKESHOT_BENCH=1 scripts/test.sh --filter MultiviewPerformance
///
/// and for the same reason — this suite shares a machine with whatever else is
/// building on it, so nothing here asserts on a clock. What the timings print is
/// the number the budget is argued from; the MINIMUM is what to compare across
/// builds, being the run that got a whole core to itself.
///
/// **The bytes are asserted**, because they are a property of the frame and the
/// constants rather than of the machine. The subject is a deterministic
/// natural-image proxy (see `MultiviewFixtures.naturalFrame`) — a flat field or
/// a colour-bar chart compresses to nothing and would flatter every setting
/// equally.
///
/// The numbers this pass was tuned against — the old code and the new one run
/// back to back in one standalone harness on the development Mac, 1080p in,
/// minimum of twenty runs. The suite's own timings come out higher than these
/// and always will: it shares its process with the rest of the harness, which
/// is exactly why nothing here asserts on them.
///
/// | case | per frame | encode |
/// | --- | --- | --- |
/// | before: 480 long edge, q0.50, affine | 6.6 KB | 1.01 ms |
/// | after: 1280 (one camera), q0.75, Lanczos | 42.9 KB | 2.61 ms |
/// | after: 960 (two cameras) | 28.4 KB | 1.55 ms |
/// | after: 640 (three or more) | 16.5 KB | 1.50 ms |
///
/// At the pace — five frames per camera per second — that is 1.7 Mbit/s for a
/// single camera and 2.6 Mbit/s for a four-up grid, against 0.3 and 1.1 before.
/// A flat 1280 cap would have made the four-up grid 7.2 Mbit/s for tiles a
/// quarter of the screen, which is what the ladder exists to refuse.
struct MultiviewPerformanceTests {
    private static var enabled: Bool {
        ProcessInfo.processInfo.environment["TAKESHOT_BENCH"] != nil
    }

    /// The rungs, each with the camera count that selects it.
    private static let rungs: [(cameras: Int, edge: CGFloat)] = [
        (1, MultiviewEncoder.soloEdge),
        (2, MultiviewEncoder.pairEdge),
        (4, MultiviewEncoder.gridEdge),
    ]

    @discardableResult
    private func time(_ label: String, runs: Int = 15,
                      _ body: () -> Void) -> Double {
        for _ in 0..<3 { body() } // warm the context and the JPEG encoder
        var samples: [Double] = []
        for _ in 0..<runs {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            samples.append(
                Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        samples.sort()
        print(String(format: "MULTIVIEWBENCH %@: min %.3f ms  median %.3f ms  max %.3f ms",
                     label, samples[0], samples[runs / 2], samples[runs - 1]))
        return samples[0]
    }

    @Test(.enabled(if: MultiviewPerformanceTests.enabled))
    func oneTileThroughTheEncoder() throws {
        let context = CIContext(options: [.cacheIntermediates: false])
        for (name, width, height) in [("1080p", 1920, 1080),
                                      ("UHD", 3840, 2160)] {
            let frame = MultiviewFixtures.naturalFrame(width: width,
                                                       height: height)
            for rung in Self.rungs {
                var bytes = 0
                time("\(name) -> \(Int(rung.edge))") {
                    bytes = MultiviewEncoder.jpeg(from: frame, context: context,
                                                  maxEdge: rung.edge)?.count ?? 0
                }
                print(String(format: "MULTIVIEWBENCH %@ -> %d: %.1f KB per frame",
                             name, Int(rung.edge), Double(bytes) / 1024))
            }
        }
    }

    /// Always run, unlike the timings: what the ladder costs the set network.
    ///
    /// Two claims, and only the second is the interesting one. Each rung has to
    /// cost less than the rung above it — otherwise the ladder is doing nothing
    /// — and a FOUR-camera page has to stay in the same order of bytes as a
    /// one-camera page, which is the whole reason the cap is a function of the
    /// count instead of a constant. Four tiles at the grid rung come to 66 KB
    /// against 86 KB for two at the solo rung, measured.
    @Test func theLadderKeepsTheWholePageInOneBudget() throws {
        let context = CIContext(options: [.cacheIntermediates: false])
        let frame = MultiviewFixtures.naturalFrame(width: 1920, height: 1080)
        var bytes: [Int: Int] = [:]
        for rung in Self.rungs {
            let jpeg = try #require(
                MultiviewEncoder.jpeg(from: frame, context: context,
                                      maxEdge: rung.edge))
            bytes[rung.cameras] = jpeg.count
            print(String(format: "MULTIVIEWBENCH %d camera(s) -> %d long edge: %d bytes",
                         rung.cameras, Int(rung.edge), jpeg.count))
        }
        let solo: Int = try #require(bytes[1])
        let pair: Int = try #require(bytes[2])
        let grid: Int = try #require(bytes[4])

        #expect(grid < pair, "the grid rung is not cheaper than the pair rung")
        #expect(pair < solo, "the pair rung is not cheaper than the solo rung")
        #expect(4 * grid < 2 * solo,
                "a four-up page costs more than two solo tiles: \(4 * grid)")

        // Bands rather than exact counts: the same constants against a
        // different release's JPEG encoder land near these, not on them. What
        // would trip these is a constant moving, which is the point.
        #expect((30_000...60_000).contains(solo), "solo tile \(solo) bytes")
        #expect((20_000...42_000).contains(pair), "pair tile \(pair) bytes")
        #expect((11_000...25_000).contains(grid), "grid tile \(grid) bytes")
    }

    /// The pace the bytes above are multiplied by is still the one the encoder
    /// documents, and it is still well under any rate the app captures — a tile
    /// stream must not turn into a second preview path.
    @Test func theEncodePaceIsUnchangedByTheLadder() {
        #expect(MultiviewEncoder.framesPerSecond == 5)
        #expect(MultiviewEncoder.minimumInterval == 0.2)
    }
}
