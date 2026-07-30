@preconcurrency import CoreImage
@preconcurrency import CoreVideo
import Foundation

/// The pinned reference compare: pinning a frame (a deep copy — pooled buffers
/// get reused), fitting it to the live frame once, and compositing it over what
/// reaches the screen.
///
/// Split out of `+Preview`, and it takes the frame path's compare decision with
/// it: the reference is an on-screen-only affair, so keeping the "who gets the
/// composite" rule next to the compositing itself is what stops it leaking into
/// the scopes, the stills or the compare provider. `CaptureController` has a
/// `+Compare` of its own — this is that feature's pipeline half.
extension CapturePipeline {
    /// Pin an already-decoded frame (deep copy — pooled buffers get reused).
    public func setPreviewReference(buffer: CVPixelBuffer?) {
        queue.async {
            self.previewReference = buffer.flatMap { self.deepCopy($0) }
        }
    }

    /// Pin the current live frame.
    public func pinReferenceFromCurrentFrame() {
        queue.async {
            guard let current = self.currentPreviewBuffer() else { return }
            self.previewReference = self.deepCopy(current)
        }
    }

    public func setPreviewCompare(_ mode: CompareCompositor.Mode) {
        queue.async {
            self.previewCompare = mode
        }
    }

    /// pinned reference compare — on screen only (scopes/stills/the
    /// compare-provider frame stay clean)
    func presentProcessedFrame(_ displayBuffer: CVPixelBuffer) {
        var screenBuffer = displayBuffer
        if let reference = previewReference {
            if case .off = previewCompare {} else {
                screenBuffer = compositeReference(reference, over: displayBuffer)
                    ?? displayBuffer
            }
        }
        enqueuePreview(pixelBuffer: displayBuffer, screen: screenBuffer)
    }

    private func deepCopy(_ buffer: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let image = CIImage(cvPixelBuffer: buffer,
                            options: [.colorSpace: NSNull()])
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var copy: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_32BGRA,
                            attrs as CFDictionary, &copy)
        guard let copy else { return nil }
        let destination = CIRenderDestination(pixelBuffer: copy)
        destination.colorSpace = nil
        guard let task = try? ciContext.startTask(toRender: image,
                                                  to: destination)
        else { return nil }
        _ = try? task.waitUntilCompleted()
        return copy
    }

    /// Reference (front, left/top of the wipe) over the live frame.
    private func compositeReference(_ reference: CVPixelBuffer,
                                    over live: CVPixelBuffer) -> CVPixelBuffer? {
        let back = CIImage(cvPixelBuffer: live, options: [.colorSpace: NSNull()])
        let front: CIImage
        if let cache = fittedReferenceCache, cache.source === reference,
           cache.extent == back.extent {
            front = cache.image
        } else {
            front = CompareCompositor.fitted(
                CIImage(cvPixelBuffer: reference, options: [.colorSpace: NSNull()]),
                into: back.extent)
            fittedReferenceCache = FittedReference(
                source: reference, extent: back.extent, image: front)
        }
        let result = CompareCompositor.compose(front: front, back: back,
                                               mode: previewCompare)
        let width = Int(back.extent.width.rounded())
        let height = Int(back.extent.height.rounded())
        guard width > 0, height > 0,
              let out = comparePool.buffer(width: width, height: height)
        else { return nil }
        let destination = CIRenderDestination(pixelBuffer: out)
        destination.colorSpace = nil
        guard let task = try? ciContext.startTask(toRender: result,
                                                  to: destination)
        else { return nil }
        _ = try? task.waitUntilCompleted()
        return out
    }
}
