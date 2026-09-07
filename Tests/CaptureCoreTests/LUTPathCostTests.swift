import CoreImage
import CoreVideo
import Foundation
import Testing

@testable import CaptureCore

/// **What the preview LUT costs the frame path, measured.**
///
/// `applyLUT` runs on the CAPTURE queue, synchronously, once per frame, and
/// waits on the GPU (`waitUntilCompleted`). That is the one place in this app
/// where a slow pass does not make a late picture — it makes a HOLE in the
/// file, because the capture queue is what appends to the writer. An audit read
/// the shape and said "not measured; the nearest analogue is the keyer at
/// 1.5 ms/1080p and 3.3 ms/UHD", and proposed moving the preview half to the
/// display queue.
///
/// So: measure it. The budget is the frame interval the operator is shooting
/// at — 40 ms at 25 fps, 16.7 ms at 60 — and what has to fit inside it is this
/// pass PLUS the levels pass, the keyer, the assist stage and the append.
///
/// Opt-in (`TAKESHOT_BENCH=1 scripts/test.sh -c release --filter LUTPathCost`)
/// and it asserts nothing about the clock: on a machine building in another
/// window the number is about the machine. What it prints is what the decision
/// is argued from.
struct LUTPathCostTests {
    private static var benching: Bool {
        ProcessInfo.processInfo.environment["TAKESHOT_BENCH"] != nil
    }

    /// An identity cube, so what is measured is the PASS and not a particular
    /// look: a LUT that changes nothing still costs a full render.
    private static func identityFilter() throws -> CIFilter {
        let size = 33
        var data = [Float](repeating: 0, count: size * size * size * 4)
        var index = 0
        for blue in 0..<size {
            for green in 0..<size {
                for red in 0..<size {
                    data[index] = Float(red) / Float(size - 1)
                    data[index + 1] = Float(green) / Float(size - 1)
                    data[index + 2] = Float(blue) / Float(size - 1)
                    data[index + 3] = 1
                    index += 4
                }
            }
        }
        let filter = try #require(CIFilter(name: "CIColorCube"))
        filter.setValue(size, forKey: "inputCubeDimension")
        filter.setValue(data.withUnsafeBufferPointer { Data(buffer: $0) },
                        forKey: "inputCubeData")
        return filter
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

    @Test(.enabled(if: LUTPathCostTests.benching))
    func whatOneLUTFrameCosts() throws {
        var settings = CaptureSettings()
        settings.capture.detectionMode = .manual
        settings.capture.preRollFrames = 0
        let pipeline = CapturePipeline(config: .init(settings: settings,
                                                     takeNumber: 1))
        let filter = try Self.identityFilter()
        for (name, width, height) in [("1080p", 1920, 1080),
                                      ("UHD", 3840, 2160)] {
            let source = try Self.buffer(width: width, height: height)
            // warm: the first render of a raster compiles the kernel
            _ = pipeline.applyLUT(to: source, using: filter)
            let full = Self.milliseconds(30) {
                _ = pipeline.applyLUT(to: source, using: filter)
            }
            // …and at partial intensity, which adds the dissolve the audit
            // named separately: a second filter built per frame.
            pipeline.setLUTIntensity(0.5)
            pipeline.queue.sync {}
            _ = pipeline.applyLUT(to: source, using: filter)
            let mixed = Self.milliseconds(30) {
                _ = pipeline.applyLUT(to: source, using: filter)
            }
            pipeline.setLUTIntensity(1)
            pipeline.queue.sync {}
            print(String(format: """
                LUTBENCH %@: full intensity %.2f ms, blended %.2f ms \
                (frame interval 40.0 ms at 25 fps, 16.7 at 60)
                """, name, full, mixed))
        }
    }

    /// …and the pinned COMPARE, which is the second pass on the same queue.
    ///
    /// Only when the operator has pinned a reference and chosen a mode, so
    /// unlike the LUT it is not a cost the frame path pays all day — but when
    /// it is on it is on for as long as somebody is comparing setups, which is
    /// exactly when a hole in the file would be least welcome.
    @Test(.enabled(if: LUTPathCostTests.benching))
    func whatOneComparedFrameCosts() throws {
        var settings = CaptureSettings()
        settings.capture.detectionMode = .manual
        settings.capture.preRollFrames = 0
        let pipeline = CapturePipeline(config: .init(settings: settings,
                                                     takeNumber: 1))
        for (name, width, height) in [("1080p", 1920, 1080),
                                      ("UHD", 3840, 2160)] {
            pipeline.handleFormat(CaptureFormat(width: width, height: height,
                                                frameRate: 25, timecodeFPS: 25,
                                                name: name))
            let source = try Self.buffer(width: width, height: height)
            pipeline.setPreviewReference(buffer: source)
            pipeline.queue.sync {}

            let modes: [(String, CompareCompositor.Mode)] = [
                ("off", .off),
                ("blend", .blend(opacity: 0.5)),
                ("wipe", .wipe(axis: .vertical, position: 0.5)),
                ("difference", .difference(gain: 4)),
            ]
            for (label, mode) in modes {
                pipeline.setPreviewCompare(mode)
                pipeline.queue.sync {}
                // warm
                pipeline.queue.sync {
                    pipeline.presentProcessedFrame(source, preLUT: source)
                }
                let cost = Self.milliseconds(20) {
                    pipeline.queue.sync {
                        pipeline.presentProcessedFrame(source, preLUT: source)
                    }
                }
                print(String(format: "LUTBENCH %@ compare %@: %.2f ms",
                             name, label, cost))
            }
            pipeline.setPreviewCompare(.off)
            pipeline.setPreviewReference(buffer: nil)
            pipeline.queue.sync {}
        }
    }
}
