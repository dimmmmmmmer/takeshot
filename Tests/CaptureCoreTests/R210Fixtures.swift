import CoreVideo
import Testing

@testable import CaptureCore

/// Flat and patterned r210 wire frames, shared by the suites that read them.
///
/// A file of its own for the reason `V210Fixtures` is one: two suites building
/// the same wire format two ways is two chances to pack it differently, and a
/// scope test that disagrees with another scope test about what its own input
/// says is the hardest kind of red to read.
enum R210Fixtures {
    /// One pixel's 10-bit wire codes.
    struct Codes {
        let r: Int
        let g: Int
        let b: Int
    }

    /// A flat r210 frame of one colour, in 10-bit wire codes.
    static func make(width: Int = 320, height: Int = 180,
                     r: Int, g: Int, b: Int) throws -> CVPixelBuffer {
        try make(width: width, height: height) { _, _ in
            Codes(r: r, g: g, b: b)
        }
    }

    /// An r210 frame whose colour is a function of the pixel.
    static func make(width: Int = 320, height: Int = 180,
                     code: (_ x: Int, _ y: Int) -> Codes) throws
        -> CVPixelBuffer {
        var out: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            TenBitConverter.r210,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                            &out)
        let buffer = try #require(out, "no r210 buffer was allocated")
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer),
                                "the r210 buffer has no base address")
        let rowBytes: Int = CVPixelBufferGetBytesPerRow(buffer)
        for y: Int in 0..<height {
            let row = base.advanced(by: y * rowBytes)
                .assumingMemoryBound(to: UInt32.self)
            for x: Int in 0..<width {
                let pixel: Codes = code(x, y)
                let red = UInt32(pixel.r & 0x3FF)
                let green = UInt32(pixel.g & 0x3FF)
                let blue = UInt32(pixel.b & 0x3FF)
                row[x] = ((red << 20) | (green << 10) | blue).bigEndian
            }
        }
        return buffer
    }
}
