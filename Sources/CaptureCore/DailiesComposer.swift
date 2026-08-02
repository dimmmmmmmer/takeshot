@preconcurrency import CoreMedia
@preconcurrency import CoreVideo
import CoreGraphics
import Foundation

/// One clip's frame path: the burn-ins (and the downscale, when the source is
/// larger than the daily) composited onto each decoded frame.
///
/// Built once per item — the overlay pre-renders its static strips here, and
/// only the timecode text is re-drawn frame to frame (see `DailiesOverlay`).
final class DailiesFrameComposer {
    private let overlay: DailiesOverlay
    /// nil — the timecode burn-in is off and no clock is computed at all.
    private let timeline: DailiesTimeline?
    private let outputSize: CGSize
    /// Scaled-path frames come from here rather than fresh allocations.
    private let pool = PixelBufferPool()

    init(item: DailiesItem, burnins: DailiesBurnins,
         facts: DailiesSourceFacts) {
        overlay = DailiesOverlay(size: facts.outputSize,
                                 texts: burnins.overlayTexts(for: item))
        timeline = facts.timeline
        outputSize = facts.outputSize
    }

    /// The frame with its burn-ins: drawn straight onto the decoded buffer
    /// when no scaling is needed (the decoder hands a fresh buffer per frame,
    /// so there is nothing to preserve), or into a pool buffer through one
    /// scaled blit when the source is larger than 1080p.
    func compose(_ source: CVPixelBuffer, pts: CMTime) throws -> CVPixelBuffer {
        let timecodeText = timeline?.text(atSeconds: pts.seconds)
        let width = Int(outputSize.width)
        let height = Int(outputSize.height)
        if CVPixelBufferGetWidth(source) == width,
           CVPixelBufferGetHeight(source) == height {
            CVPixelBufferLockBaseAddress(source, [])
            defer { CVPixelBufferUnlockBaseAddress(source, []) }
            guard let context = Self.bgraContext(for: source) else {
                throw DailiesAbort.failed("cannot draw on the frame")
            }
            overlay.draw(in: context, timecodeText: timecodeText)
            return source
        }
        guard let destination = pool.buffer(width: width, height: height) else {
            throw DailiesAbort.failed("cannot allocate a \(width)x\(height) frame")
        }
        CVPixelBufferLockBaseAddress(source, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        CVPixelBufferLockBaseAddress(destination, [])
        defer { CVPixelBufferUnlockBaseAddress(destination, []) }
        guard let sourceImage = Self.bgraContext(for: source)?.makeImage(),
              let context = Self.bgraContext(for: destination) else {
            throw DailiesAbort.failed("cannot draw on the frame")
        }
        context.interpolationQuality = .medium
        context.draw(sourceImage, in: CGRect(x: 0, y: 0,
                                             width: width, height: height))
        overlay.draw(in: context, timecodeText: timecodeText)
        return destination
    }

    /// A CG context over a locked BGRA pixel buffer (the caller holds the
    /// lock for the context's whole lifetime).
    private static func bgraContext(for buffer: CVPixelBuffer) -> CGContext? {
        CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: CVPixelBufferGetWidth(buffer),
            height: CVPixelBufferGetHeight(buffer),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpace(name: CGColorSpace.sRGB)
                ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                | CGImageAlphaInfo.premultipliedFirst.rawValue)
    }
}
