import CoreImage
import CoreVideo
import Foundation
import Testing

@testable import TakeShotKit

/// **What a `CIContext` per decode actually costs.**
///
/// The thumbnail path, the Other-content decode and the still grab each build
/// their own context and throw it away. An audit read that as "two hundred R3D
/// files in a folder is two hundred contexts" and proposed one shared context.
/// `CIBufferRender` argues the other way in its own comment — a context holds
/// caches sized for the work it has seen, and these are one-shot decodes off
/// the main actor.
///
/// Neither argument is a number. Opt-in
/// (`TAKESHOT_BENCH=1 scripts/test.sh -c release --filter ThumbnailContextCost`)
/// and it asserts nothing about the clock: what it prints is what the decision
/// is argued from.
struct ThumbnailContextCostTests {
    private static var benching: Bool {
        ProcessInfo.processInfo.environment["TAKESHOT_BENCH"] != nil
    }

    private static func buffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var made: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey:
                                [:] as CFDictionary] as CFDictionary, &made)
        return try #require(made)
    }

    private static func milliseconds(_ runs: Int,
                                     _ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<runs { body() }
        return Double(DispatchTime.now().uptimeNanoseconds - start)
            / 1e6 / Double(runs)
    }

    @Test(.enabled(if: ThumbnailContextCostTests.benching))
    func buildingAContextAgainstReusingOne() throws {
        // Warm the frameworks up so the first Metal device lookup is not in
        // the number.
        _ = CIContext(options: [.cacheIntermediates: false])
        let build = Self.milliseconds(50) {
            _ = CIContext(options: [.cacheIntermediates: false])
        }
        print(String(format: "THUMBBENCH one CIContext: %.3f ms", build))

        let source = try Self.buffer(width: 1920, height: 1080)
        let image = CIImage(cvPixelBuffer: source)
        let scaled = image.transformed(
            by: CGAffineTransform(scaleX: 0.1, y: 0.1))

        let fresh = Self.milliseconds(20) {
            let context = CIContext(options: [.cacheIntermediates: false])
            _ = context.createCGImage(scaled, from: scaled.extent)
        }
        let shared = CIContext(options: [.cacheIntermediates: false])
        let reused = Self.milliseconds(20) {
            _ = shared.createCGImage(scaled, from: scaled.extent)
        }
        print(String(format: """
            THUMBBENCH 1080p → 192x108 thumbnail: fresh context %.3f ms, \
            shared %.3f ms (%.2fx)
            """, fresh, reused, fresh / max(0.0001, reused)))
    }

    /// **The one-shot decodes go through the shared context, and the running
    /// stages do not.**
    ///
    /// Always asserted, unlike the timing above: what the numbers argued for
    /// is a decision, and a decision that nothing holds in place is a comment.
    /// A fresh `CIContext` in any of these files is ten times the cost per
    /// decode and would be invisible — the thumbnails still appear, a little
    /// later, on a scan that already takes a while.
    @Test func theOneShotDecodesShareOneContext() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TakeShotKit")
        for name in ["CaptureController+ThumbnailDecode", "CIBufferRender",
                     "CaptureController+Stills", "RemoteAddress"] {
            let source = try String(
                contentsOf: root.appendingPathComponent("\(name).swift"),
                encoding: .utf8)
            let code = source.components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces)
                    .hasPrefix("//") }
                .joined(separator: "\n")
            #expect(!code.contains("CIContext("),
                    "\(name) builds its own context for a one-shot decode")
        }

        // …and the RUNNING stages keep theirs, which is what makes the line
        // above a decision rather than a blanket rule. A frame path behind the
        // same context as a folder scan would wait on a thumbnail.
        for name in ["PlayoutFeeder", "MultiviewComposer", "PlaybackFrameTap",
                     "RawClipSource"] {
            let source = try String(
                contentsOf: root.appendingPathComponent("\(name).swift"),
                encoding: .utf8)
            #expect(source.contains("CIContext("),
                    "\(name) no longer owns its own context")
        }
    }
}
