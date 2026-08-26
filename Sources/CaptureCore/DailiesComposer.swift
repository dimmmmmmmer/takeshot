@preconcurrency import CoreMedia
@preconcurrency import CoreVideo
import CoreGraphics
import Foundation

/// One clip's frame path: the picture's own levels, then the burn-ins (and the
/// downscale, when the source is larger than the daily) composited onto each
/// decoded frame.
///
/// Built once per item — the overlay pre-renders its static strips here, and
/// only the timecode text is re-drawn frame to frame (see `DailiesOverlay`).
final class DailiesFrameComposer {
    private let overlay: DailiesOverlay
    /// nil — the timecode burn-in is off and no clock is computed at all.
    private let timeline: DailiesTimeline?
    private let outputSize: CGSize
    /// The source's own levels lookup; nil — the picture is left alone.
    private let levels: [UInt8]?
    /// What the source file said its codes mean. Read at probe time, so a
    /// mid-run anything cannot change the answer under the frame loop.
    private let colorimetry: WireColorimetry
    /// Scaled-path frames come from here rather than fresh allocations.
    private let pool = PixelBufferPool()

    init(item: DailiesItem, burnins: DailiesBurnins,
         facts: DailiesSourceFacts) {
        overlay = DailiesOverlay(size: facts.outputSize,
                                 texts: burnins.overlayTexts(for: item))
        timeline = facts.timeline
        outputSize = facts.outputSize
        levels = facts.levels
        colorimetry = facts.colorimetry
    }

    /// One decoded frame as the proxy should hold it: levelled, burned in, and
    /// tagged for what its codes now are.
    ///
    /// The ORDER is the whole trap. The lookup is the PICTURE's and only the
    /// picture's, so it runs while the frame is still nothing but picture —
    /// after the strips exist it would tone map them too, and a burn-in whose
    /// white has been rolled down a shoulder is a grey strip that no longer
    /// reads over a blown-out sky, which is the one thing burn-ins are for.
    func compose(_ source: CVPixelBuffer, pts: CMTime) throws -> CVPixelBuffer {
        if let levels {
            // In place, like the burn-ins below: the decoder hands a fresh
            // buffer per frame and this path is the only thing looking at it.
            StudioSwing.map(source, into: source, table: levels)
        }
        let frame = try burnedIn(source, pts: pts)
        // The codes MEAN something else now — an HDR take reaches here on a
        // Rec.709 curve — and a writer-bound buffer that still claims PQ is
        // the tag mismatch this project has already been bitten by: the
        // encoder colour-converts on it, and the file inherits the claim.
        if colorimetry.isHDR {
            ColorTags.tag(frame, preset: colorimetry.displayPreset)
        }
        return frame
    }

    /// The frame with its burn-ins: drawn straight onto the decoded buffer
    /// when no scaling is needed (the decoder hands a fresh buffer per frame,
    /// so there is nothing to preserve), or into a pool buffer through one
    /// scaled blit when the source is larger than 1080p.
    private func burnedIn(_ source: CVPixelBuffer,
                          pts: CMTime) throws -> CVPixelBuffer {
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
