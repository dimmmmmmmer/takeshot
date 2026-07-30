import CoreImage
import CoreVideo
import Foundation

/// Rendering a `CIImage` into a fresh full-range BGRA pixel buffer — the one
/// representation every surface in this app draws.
///
/// Two callers reach a still this way: the compare reference the operator pins
/// from a photo in the record folder, and a still opened in the player. Both
/// had their own copy of the pool-free create/render dance, including the
/// `destination.colorSpace` line, which is the part that must NOT be got wrong
/// — see the parameter.
enum CIBufferRender {
    /// `colorSpace` nil means colour management OFF: the code values pass
    /// through untouched, which is what the live and playback paths do and what
    /// makes a pinned reference comparable with the picture beside it. A file
    /// from outside is rendered INTO a space instead (Rec.709), so a foreign
    /// profile is converted exactly once, here, rather than by whatever draws
    /// it later.
    static func render(_ image: CIImage, width: Int, height: Int,
                       into colorSpace: CGColorSpace?) -> CVPixelBuffer? {
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_32BGRA,
                            attrs as CFDictionary, &buffer)
        guard let buffer else { return nil }
        let destination = CIRenderDestination(pixelBuffer: buffer)
        destination.colorSpace = colorSpace
        // Its own context, not a shared one: both callers run off the main
        // actor on a one-shot decode, and a CIContext holds caches sized for
        // the work it has seen.
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let task = try? context.startTask(toRender: image, to: destination),
              (try? task.waitUntilCompleted()) != nil else { return nil }
        return buffer
    }
}
