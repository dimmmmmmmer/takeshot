import CoreImage
import CoreVideo
import Foundation
import Testing

@testable import CaptureCore

/// **A `.cube` is applied to the picture's CODES** — the way Resolve applies
/// one, and the way whoever authored it meant it to be applied.
///
/// This is a measurement and not a preference. The filter used to be
/// `CIColorCubeWithColorSpace` with Rec.709 in it, which converts the source
/// INTO that space before indexing: correct for a colour-managed image, and a
/// second encode for one whose pixels already are the codes — every image in
/// this app is built unmanaged, so the cube was being handed `OETF(code)`
/// instead of `code`. Every surface did it together, so the app agreed with
/// itself and with no other tool on set.
@Suite struct CubeFilterTests {
    /// A cube that halves every channel — linear, so trilinear interpolation
    /// between its eight corners is exact everywhere and the expected answer
    /// is arithmetic rather than a table.
    private func halvingCube() throws -> CubeLUT {
        var text = "LUT_3D_SIZE 2\n"
        for blue in 0...1 {
            for green in 0...1 {
                for red in 0...1 {
                    text += "\(Double(red) / 2) \(Double(green) / 2) "
                        + "\(Double(blue) / 2)\n"
                }
            }
        }
        return try CubeLUT.parse(text, name: "half")
    }

    private func flat(_ level: UInt8) -> CVPixelBuffer {
        let buffer = TestMedia.pixelBuffer(width: 32, height: 16)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return buffer }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for row in 0..<16 {
            let line = bytes + row * rowBytes
            for column in 0..<32 {
                line[column * 4] = level
                line[column * 4 + 1] = level
                line[column * 4 + 2] = level
                line[column * 4 + 3] = 255
            }
        }
        return buffer
    }

    private func centre(of buffer: CVPixelBuffer) -> Int {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return -1 }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let row = bytes + 8 * CVPixelBufferGetBytesPerRow(buffer)
        return Int(row[16 * 4 + 1])
    }

    /// Half of the code in, half of the code out — at four levels, because a
    /// space conversion in the loop is a CURVE and would agree with a straight
    /// line at one point by accident.
    @Test func aLookIsAppliedToTheCodeValues() throws {
        let filter = try #require(try halvingCube().makeFilter())
        for level in [64, 128, 180, 240] {
            let input = CIImage(cvPixelBuffer: flat(UInt8(level)),
                                options: [.colorSpace: NSNull()])
            filter.setValue(input, forKey: kCIInputImageKey)
            let output = try #require(filter.outputImage)
            let rendered = try #require(Self.render(output))
            let found = centre(of: rendered)
            #expect(abs(found - level / 2) <= 1, """
                code \(level) came back \(found) — half of it is \(level / 2), \
                and anything else is a colour space in the lookup
                """)
        }
    }

    private static func render(_ image: CIImage) -> CVPixelBuffer? {
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 32, 16,
                            kCVPixelFormatType_32BGRA, attrs as CFDictionary,
                            &buffer)
        guard let buffer else { return nil }
        let destination = CIRenderDestination(pixelBuffer: buffer)
        destination.colorSpace = nil
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let task = try? context.startTask(toRender: image, to: destination),
              (try? task.waitUntilCompleted()) != nil else { return nil }
        return buffer
    }
}
