import CoreVideo
import Foundation
import Testing

@testable import TakeShotKit

/// What the composer handed back, from its own queue.
///
/// Shared by the two composer suites — the layout and render one, and the
/// pacing one — because both drive the composer the way the app does (offer per
/// camera, sink on the composer's queue) rather than by reassembling the pass.
final class ComposedFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    private var buffer: CVPixelBuffer?
    private var storedRate = 0.0
    private var armed = false
    private let done = DispatchSemaphore(value: 0)

    func record(_ frame: CVPixelBuffer, rate: Double) {
        let first: Bool = lock.withLock {
            stored += 1
            buffer = frame
            storedRate = rate
            guard armed else { return false }
            armed = false
            return true
        }
        if first { done.signal() }
    }

    /// Arm, then wait for the FIRST frame after arming — the same shape, and
    /// for the same reason, as `SRTPerformanceTests.CountingStream`: a plain
    /// counting semaphore leaves credits behind and the next wait returns
    /// instantly on a frame that was already composed.
    func arm() { lock.withLock { armed = true } }

    func waitForFrame() { _ = done.wait(timeout: .now() + 5) }

    var count: Int { lock.withLock { stored } }
    var latest: CVPixelBuffer? { lock.withLock { buffer } }
    var rate: Double { lock.withLock { storedRate } }
}

/// The frames the composer suites offer and the way they read one back.
enum ComposerProbe {
    /// A flat field of one code, as a buffer the composer can be offered.
    static func buffer(code: UInt8, width: Int,
                       height: Int) throws -> CVPixelBuffer {
        let out: CVPixelBuffer = try buffer(width: width, height: height)
        CVPixelBufferLockBaseAddress(out, [])
        if let base = CVPixelBufferGetBaseAddress(out) {
            let stride = CVPixelBufferGetBytesPerRow(out)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                for x in 0..<width {
                    let pixel = bytes + y * stride + x * 4
                    pixel[0] = code
                    pixel[1] = code
                    pixel[2] = code
                    pixel[3] = 0xFF
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(out, [])
        return out
    }

    static func buffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var made: CVPixelBuffer?
        let attributes: CFDictionary =
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_32BGRA, attributes, &made)
        return try #require(made)
    }

    static func level(of buffer: CVPixelBuffer, atX x: Int, y: Int) -> Int {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return -1 }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let pixel = base.advanced(by: y * stride + x * 4)
            .assumingMemoryBound(to: UInt8.self)
        return Int(pixel[2]) // BGRA: red
    }

    /// Whether the opt-in timings run. Same gate as the rest of the project's
    /// benchmarks: `TAKESHOT_BENCH=1 scripts/test.sh --filter Multiview`.
    static var timed: Bool {
        ProcessInfo.processInfo.environment["TAKESHOT_BENCH"] != nil
    }
}
