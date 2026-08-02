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
    /// The buffer arrives clean (a playback frame or a still off disk, neither
    /// carries the preview LUT), so the one copy serves both compare stages.
    public func setPreviewReference(buffer: CVPixelBuffer?) {
        queue.async {
            let copy = buffer.flatMap { self.deepCopy($0) }
            self.previewReference = copy
            self.previewReferencePreLUT = copy
        }
    }

    /// Pin the current live frame — as the operator sees it (for wipe/blend)
    /// AND at the pre-LUT stage (for difference). With no preview LUT the two
    /// are the same frame, and one copy serves both.
    public func pinReferenceFromCurrentFrame() {
        queue.async {
            guard let current = self.currentPreviewBuffer() else { return }
            let copy = self.deepCopy(current)
            self.previewReference = copy
            let preLUT = self.currentPreLUTPreviewBuffer()
            self.previewReferencePreLUT = (preLUT == nil || preLUT === current)
                ? copy : preLUT.flatMap { self.deepCopy($0) }
        }
    }

    public func setPreviewCompare(_ mode: CompareCompositor.Mode) {
        queue.async {
            self.previewCompare = mode
        }
    }

    /// pinned reference compare — on screen only (scopes/stills/the
    /// compare-provider frame stay clean)
    ///
    /// Wipe and blend composite the DISPLAY frame — both halves carry the
    /// preview LUT, which is what makes the seam fair. Difference is the
    /// opposite contract: it is a measurement of the signal, so it reads the
    /// pre-LUT frame against the pre-LUT pin and its output bypasses the
    /// viewing LUT entirely — a look bent over |A−B| would bend the very
    /// numbers the operator is checking.
    func presentProcessedFrame(_ displayBuffer: CVPixelBuffer,
                               preLUT: CVPixelBuffer) {
        var screenBuffer = displayBuffer
        switch previewCompare {
        case .off:
            break
        case .difference:
            if let reference = previewReferencePreLUT {
                screenBuffer = compositeReference(reference, over: preLUT)
                    ?? displayBuffer
            }
        case .blend, .wipe:
            if let reference = previewReference {
                screenBuffer = compositeReference(reference, over: displayBuffer)
                    ?? displayBuffer
            }
        }
        enqueuePreview(pixelBuffer: displayBuffer, preLUT: preLUT,
                       screen: screenBuffer)
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
