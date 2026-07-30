@preconcurrency import CoreImage
@preconcurrency import CoreVideo
import Metal
@preconcurrency import QuartzCore

/// The draw path: what the producer queues hand in, and what reaches the
/// drawable. Everything here runs on `redrawQueue` and holds `renderLock`
/// across the GPU work.
///
/// Split out of MetalPreviewLayer, whose body had grown past 380 lines.
extension MetalPreviewLayer {
    /// Adopt a size requested by the view. Call under renderLock only.
    func applyPendingDrawableSize() {
        stateLock.lock()
        let requested = pendingDrawableSize
        pendingDrawableSize = nil
        stateLock.unlock()
        if let requested, requested != drawableSize {
            drawableSize = requested
        }
    }

    /// Re-render the last frame (window resized while paused/no signal —
    /// otherwise the old drawable stretches to the new bounds).
    ///
    /// Runs off the caller's thread: every trigger for a redraw is a UI event
    /// (letterbox color, assist sliders, punch-in pan, layout), and rendering
    /// can park for ~1 s inside `nextDrawable()` when the window is occluded or
    /// the external monitor sleeps — long enough to freeze the REC button
    /// mid-take. Re-rendering always picks up the newest `lastBuffer`, so
    /// running late cannot show a stale frame.
    public func redraw() {
        redrawQueue.async { [weak self] in
            guard let self else { return }
            renderLock.lock()
            let buffer = lastBuffer // strong read under the lock: present() swaps
            renderLock.unlock()     // it concurrently on the producer queue
            guard let buffer else { return }
            render(buffer)
        }
    }

    /// Blank the layer (signal loss) instead of freezing the last frame.
    /// Queued like every other render, so it cannot overtake or be overtaken by
    /// a frame that was already on its way.
    public func clearToBlack() {
        redrawQueue.async { [weak self] in self?.clearToBlackNow() }
    }

    private func clearToBlackNow() {
        renderLock.lock()
        defer { renderLock.unlock() }
        lastBuffer = nil
        guard let ciContext else { return }
        applyPendingDrawableSize()
        let size = drawableSize
        guard size.width > 1, size.height > 1,
              let drawable = nextDrawable() else { return }
        let bounds = CGRect(origin: .zero, size: size)
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0))
            .cropped(to: bounds)
        let destination = CIRenderDestination(mtlTexture: drawable.texture,
                                              commandBuffer: nil)
        destination.colorSpace = nil
        if let task = try? ciContext.startTask(toRender: black, to: destination) {
            _ = try? task.waitUntilCompleted()
        }
        drawable.present()
    }

    /// Show a frame. Safe to call from any thread — the main one included: the
    /// work is handed to this layer's own queue, latest frame wins.
    ///
    /// Rendering can park for ~1 s inside `nextDrawable()` when the window is
    /// occluded or an external monitor sleeps. Done inline, that stalled every
    /// other sink sharing the producer's queue, and blocked the main thread
    /// outright wherever the mount code presented directly.
    public func present(_ pixelBuffer: CVPixelBuffer) {
        stateLock.lock()
        pendingPresent = pixelBuffer
        let schedule = !presentScheduled
        presentScheduled = true
        stateLock.unlock()
        guard schedule else { return } // a newer frame replaces the pending one
        redrawQueue.async { [weak self] in
            guard let self else { return }
            stateLock.lock()
            let buffer = pendingPresent
            pendingPresent = nil
            presentScheduled = false
            stateLock.unlock()
            guard let buffer else { return }
            render(buffer)
        }
    }

    /// Draw a frame (any CoreImage-supported pixel format), aspect-fit.
    /// Runs on redrawQueue; pixel values are passed through unmanaged — the
    /// layer's `colorspace` tells the compositor what they mean.
    func render(_ pixelBuffer: CVPixelBuffer) {
        guard let ciContext else { return }
        renderLock.lock()
        defer { renderLock.unlock() }
        lastBuffer = pixelBuffer
        logProbeIfTagged(pixelBuffer)
        applyPendingDrawableSize()
        let size = drawableSize
        // one chain: no drawable yet, or nothing to place in it, and the frame
        // is skipped — `lastBuffer` above means a redraw picks it up later
        guard size.width > 1, size.height > 1,
              let drawable = nextDrawable(),
              let image = placedImage(from: pixelBuffer, in: size) else { return }
        let bounds = CGRect(origin: .zero, size: size)
        stateLock.lock()
        let letterbox = storedLetterboxColor
        stateLock.unlock()
        let composed = image.composited(over:
            CIImage(color: letterbox).cropped(to: bounds))
        // color management off on both ends: code values pass through unchanged,
        // and the layer's `colorspace` alone tells the compositor what they mean
        let destination = CIRenderDestination(mtlTexture: drawable.texture,
                                              commandBuffer: nil)
        destination.colorSpace = nil
        guard let task = try? ciContext.startTask(toRender: composed,
                                                  to: destination) else { return }
        _ = try? task.waitUntilCompleted()
        drawable.present()
    }

    /// The frame with the assists applied, scaled and translated into a
    /// `size` drawable. nil when the image has no extent to place.
    /// Call under renderLock — `assist` is read here.
    private func placedImage(from pixelBuffer: CVPixelBuffer,
                             in size: CGSize) -> CIImage? {
        var image = CIImage(cvPixelBuffer: pixelBuffer,
                            options: [.colorSpace: NSNull()])
        let currentAssist = assist
        if currentAssist.anyToolActive {
            image = applyAssist(image, assist: currentAssist)
        }
        if currentAssist.desqueeze != 1 {
            image = image.transformed(by: CGAffineTransform(
                scaleX: currentAssist.desqueeze, y: 1))
        }
        // aspect-fit, punch-in and pan in one place (ViewAssist.placement): the
        // framelines/safe-area overlays transform through the same call, which
        // is what keeps them on the signal's geometry instead of the window's
        guard let placed = currentAssist.placement(sourceSize: image.extent.size,
                                                   in: size) else { return nil }
        // integral-pixel placement: fractional offsets shift live vs playback
        // by a visible pixel in the compare modes (wipe/blend/side-by-side)
        let tx = placed.rect.minX.rounded(.down)
        // the placement is stated in view coordinates (y down); CI's y grows up
        let ty = (size.height - placed.rect.maxY).rounded(.down)
        return image
            .transformed(by: CGAffineTransform(scaleX: placed.scale, y: placed.scale)
                .concatenating(CGAffineTransform(translationX: tx, y: ty)))
    }
}
