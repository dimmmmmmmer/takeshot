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
            self.publishReference()
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
            self.publishReference()
        }
    }

    /// Show the pinned reference on a surface of its own.
    ///
    /// **The A/B split in record mode is why this exists.** Wipe, blend and
    /// difference composite the reference INTO the live frame, so the one
    /// display sink carries both halves and no second surface is needed. A
    /// split is two pictures, and the operator's half of it — the live signal —
    /// is already a surface; the reference had no way onto the screen except
    /// through the compositor, so choosing A/B in record mode drew nothing at
    /// all (owner: "а/б режим при пине рефа на странице река не работает").
    ///
    /// Fed on pin and on attach, and never per frame: a still that has not
    /// changed does not need repainting sixty times a second.
    public func addReferenceSink(_ layer: MetalPreviewLayer) {
        referenceSinks.add(layer)
        // The frame right away, the way `addDisplaySink` does it — a reference
        // is never pushed again, so a surface that waited for the next one
        // would wait for ever.
        queue.async {
            if let reference = self.previewReference {
                layer.present(reference)
            } else {
                layer.clearToBlack()
            }
        }
    }

    public func removeReferenceSink(_ layer: MetalPreviewLayer) {
        referenceSinks.remove(layer)
    }

    /// Hand whatever is pinned to every surface showing it on its own.
    ///
    /// Called from the queue that owns `previewReference`, so the buffer it
    /// publishes is the one that was just stored rather than one a concurrent
    /// pin has replaced.
    func publishReference() {
        let reference = previewReference
        let layers = referenceSinks.all()
        guard !layers.isEmpty else { return }
        for layer in layers {
            if let reference {
                layer.present(reference)
            } else {
                layer.clearToBlack()
            }
        }
    }

    /// Install (or clear) the source of a MOVING reference.
    ///
    /// Called from the main actor when a reference clip starts or stops
    /// playing; read on the capture queue, once per live frame. Behind a lock
    /// rather than hopped onto the queue for the same reason
    /// `displayFrameHandler` is: the reader is the frame path and the writer
    /// is an operator's action, and a `queue.async` write would leave one frame
    /// composited against the reference the operator has just unpinned.
    ///
    /// Nil restores the still pin, which is never thrown away while a clip
    /// plays — see `referenceFrameProvider`.
    public func setReferenceFrameProvider(
        _ provider: (@Sendable () -> CVPixelBuffer?)?) {
        referenceFrameLock.lock()
        referenceFrameProvider = provider
        referenceFrameLock.unlock()
    }

    /// The reference frame to composite right now: the moving one if a clip is
    /// playing and has produced a frame, the pinned still otherwise.
    func currentReferenceFrame(fallback: CVPixelBuffer?) -> CVPixelBuffer? {
        referenceFrameLock.lock()
        let provider = referenceFrameProvider
        referenceFrameLock.unlock()
        return provider?() ?? fallback
    }

    /// Show a frame on every surface carrying the reference on its own, from
    /// the CALLER's queue.
    ///
    /// **Never call this from `queue`.** It exists so a reference clip's own
    /// decode queue can paint the A/B pane at the clip's frame rate without
    /// the capture queue being involved at all: that queue appends to the
    /// writer, and a slow pass on it is not a late picture but a hole in the
    /// file. `publishReference` is the other entry — the pin's — and it is the
    /// one that runs on `queue`.
    public func presentReference(_ buffer: CVPixelBuffer) {
        for layer in referenceSinks.all() { layer.present(buffer) }
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
    /// **Measured, on the capture queue like the LUT before it.**
    ///
    /// Only when the operator has pinned a reference AND chosen a mode, so
    /// unlike the LUT it is not a cost the frame path pays all day — with the
    /// mode off it is one comparison and 0.00 ms. When it is on it is on for
    /// as long as somebody is comparing setups, which is exactly when a hole
    /// in the file would be least welcome.
    ///
    /// Measured, release (`LUTPathCostTests`): **0.58–0.74 ms at 1080p,
    /// 1.41–1.47 ms at UHD**, the same for all three modes — the composite is
    /// one CoreImage pass whatever it is compositing. See `applyLUT` for what
    /// that adds up to against a frame interval.
    func presentProcessedFrame(_ displayBuffer: CVPixelBuffer,
                               preLUT: CVPixelBuffer) {
        var screenBuffer = displayBuffer
        switch previewCompare {
        case .off:
            break
        case .difference:
            // A moving reference feeds BOTH stages from one frame, on the
            // argument `setPreviewReference` already makes about a pin: a
            // decoded clip carries no preview LUT either, so the frame the
            // operator sees and the frame the difference measures are the
            // same one.
            if let reference = currentReferenceFrame(
                fallback: previewReferencePreLUT) {
                screenBuffer = compositeReference(reference, over: preLUT)
                    ?? displayBuffer
            }
        case .blend, .wipe:
            if let reference = currentReferenceFrame(
                fallback: previewReference) {
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
        // **The cache survives a MOVING reference — measured, not assumed.**
        // It keys on the buffer's identity, and a playing clip's frames come
        // out of a pool, so the same object arrives with different pixels in
        // it: the case `===` cannot see. It does not need to. What is cached
        // is the FIT — a transform and a letterbox around a `CIImage` that
        // reads the buffer lazily — so the next render pulls the bytes that
        // are in it now. A bypass was written for this on the assumption that
        // a cached image is a snapshot; the test that was supposed to prove it
        // passed with the bypass mutated out, which is what says the
        // assumption was wrong (`aMovingReferenceIsNotServedFromTheFitted-
        // Cache`, which now pins the real property: a recycled buffer's new
        // pixels reach the composite).
        if let cache = fittedReferenceCache,
           cache.source === reference, cache.extent == back.extent {
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
