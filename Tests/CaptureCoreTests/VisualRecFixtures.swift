import CoreVideo
import Foundation

@testable import CaptureCore

/// Synthetic monitoring output for the taught-indicator suites: a flat picture
/// with rectangles painted on it, which is all a record overlay is.
///
/// One fixture rather than one per suite, because every suite here needs the
/// same four pictures — idle, rolling, rolling-shaped-but-somewhere-else, and
/// something untaught sitting on the box — and the whole point of the metric is
/// how it tells those four apart.
enum VisualRecProbe {
    /// The frame size the suites work at: big enough that the default box is
    /// tens of pixels across, small enough to encode in real time.
    static let width = 640
    static let height = 360

    /// A display-RGB triple. A named struct rather than three loose bytes, which
    /// is this project's rule and the linter's — three anonymous numbers in a row
    /// is how channels get swapped.
    struct Ink: Equatable {
        let r: UInt8
        let g: UInt8
        let b: UInt8
    }

    struct Block {
        let x: Int
        let y: Int
        let width: Int
        let height: Int
        let color: Ink
    }

    /// Where the camera puts its record indicator in these fixtures, as SIGNAL
    /// fractions — the units the taught region is in.
    static let indicatorX = 0.80
    static let indicatorY = 0.12

    /// The dot itself: 24 × 24 px centred on the indicator position, so it fills
    /// part of the default box and not all of it. A real indicator does the same,
    /// which is why the box averages cells rather than the whole region.
    static var dot: Block {
        Block(x: Int(indicatorX * Double(width)) - 12,
              y: Int(indicatorY * Double(height)) - 12,
              width: 24, height: 24, color: Ink(r: 220, g: 30, b: 30))
    }

    /// A red practical, or a costume: the same red as the dot, sixteen times the
    /// area, and nowhere near the box.
    static var practical: Block {
        Block(x: 40, y: 220, width: 200, height: 110,
              color: Ink(r: 220, g: 30, b: 30))
    }

    /// The camera's own menu overlay, dropped straight over the box — an
    /// untaught change to the very pixels the trigger watches.
    static var menuOverlay: Block {
        Block(x: Int(indicatorX * Double(width)) - 40,
              y: Int(indicatorY * Double(height)) - 30,
              width: 80, height: 60, color: Ink(r: 235, g: 235, b: 235))
    }

    /// The region the operator would mark on that indicator.
    static func region(size: Double = VisualRecRegion.defaultSize)
        -> VisualRecRegion {
        VisualRecRegion(centerX: indicatorX, centerY: indicatorY, width: size)
    }

    /// The flat picture the fixtures are painted on. Its own constant so a test
    /// can assert "nothing was drawn here" against the same numbers.
    static let background = Ink(r: 60, g: 62, b: 64)

    /// A BGRA frame: the flat background, with `blocks` painted on it.
    static func frame(_ blocks: [Block] = [],
                      background: Ink = background,
                      width: Int = width, height: Int = height) -> CVPixelBuffer {
        let buffer = TestMedia.pixelBuffer(width: width, height: height)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return buffer }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        // scale the blocks with the raster, so the same picture can be built at
        // two resolutions and compared (see the signal-coordinates test)
        let scaleX = Double(width) / Double(self.width)
        let scaleY = Double(height) / Double(self.height)
        for y in 0..<height {
            let row = bytes + y * rowBytes
            for x in 0..<width {
                var color = background
                for block in blocks {
                    let bx = Int(Double(block.x) * scaleX)
                    let by = Int(Double(block.y) * scaleY)
                    let bw = max(1, Int(Double(block.width) * scaleX))
                    let bh = max(1, Int(Double(block.height) * scaleY))
                    if x >= bx, x < bx + bw, y >= by, y < by + bh {
                        color = block.color
                    }
                }
                row[x * 4] = color.b
                row[x * 4 + 1] = color.g
                row[x * 4 + 2] = color.r
                row[x * 4 + 3] = 255
            }
        }
        return buffer
    }

    /// A teaching captured from two frames, with the box on the indicator.
    /// The margin is no longer a parameter: it is derived from the separation
    /// the two references actually have, so a fixture cannot set it to a value
    /// the teaching it describes would not produce.
    static func taught(rolling: CVPixelBuffer, idle: CVPixelBuffer,
                       region: VisualRecRegion = region(),
                       on: Bool = true) -> VisualRecTeaching {
        var teaching = VisualRecTeaching()
        teaching.region = region
        teaching.rolling = VisualRecSampler.signature(of: rolling, region: region)
        teaching.idle = VisualRecSampler.signature(of: idle, region: region)
        teaching.isOn = on
        return teaching
    }

    /// The reading a teaching gives a frame — the whole path in one call.
    static func reading(_ teaching: VisualRecTeaching,
                        of buffer: CVPixelBuffer) -> VisualRecReading? {
        guard let signature = VisualRecSampler.signature(
            of: buffer, region: teaching.region) else { return nil }
        return teaching.reading(of: signature)
    }

    static func position(_ teaching: VisualRecTeaching, of buffer: CVPixelBuffer)
        -> (along: Double, residual: Double)? {
        guard let signature = VisualRecSampler.signature(
            of: buffer, region: teaching.region) else { return nil }
        return teaching.position(of: signature)
    }
}
