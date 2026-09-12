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
    /// **Latest-wins.** Every trigger is a UI event and the loudest of them is
    /// a drag: a slider delivers about sixty changes a second, and each one used
    /// to queue a full render. A render can park for a second inside
    /// `nextDrawable()` when the window is occluded or an external monitor
    /// sleeps, so the queue grew for as long as the finger moved and the
    /// picture followed it a second late (owner: "лагает action safe, title
    /// safe", "лагают и ползунки высоты и ширины").
    ///
    /// Dropping the ones in between cannot show a stale frame: a redraw takes
    /// `lastBuffer` and `currentAssist` when it RUNS, so whichever pass runs
    /// last draws the value the operator settled on. The flag is cleared at the
    /// start of the pass, so a change arriving mid-render schedules one more.
    public func redraw() {
        stateLock.lock()
        let schedule = !redrawScheduled
        redrawScheduled = true
        stateLock.unlock()
        guard schedule else { return }
        redrawQueue.async { [weak self] in
            guard let self else { return }
            stateLock.lock()
            redrawScheduled = false
            stateLock.unlock()
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
        adoptColorSpace(of: pixelBuffer)
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
        // the bars are painted, not left to what shows through beside a fitted
        // picture: see `CIImage.letterboxed(in:with:)` — an extent alone is not
        // enough to keep the picture's edge column out of the bar beside it
        let composed = image.letterboxed(in: bounds, with: letterbox)
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

    /// Follow the frame's own primaries, when they are not the ones the layer
    /// is already built for.
    ///
    /// The layer renders unmanaged and its `colorspace` is the whole statement
    /// of what the codes reaching the compositor mean, so a Rec.2020 frame
    /// shown through a Rec.709 layer is a real error: ColorSync would map the
    /// wrong gamut to the display and every saturated colour would land short.
    /// Reading it off the buffer rather than from a setting is what lets one
    /// layer serve live, playback and RAW without any of them telling it
    /// anything.
    ///
    /// Costs one attachment lookup and one `CFEqual` per presented frame; the
    /// body runs only when the source's primaries actually change, which for an
    /// SDR session is never. Assigning `colorspace` reallocates the drawable
    /// pool, so it must not happen per frame — that is what the comparison is
    /// for, not an optimisation.
    ///
    /// Call under renderLock, before `nextDrawable()`.
    func adoptColorSpace(of pixelBuffer: CVPixelBuffer) {
        let tagged = CVBufferCopyAttachment(
            pixelBuffer, kCVImageBufferColorPrimariesKey, nil)
        // an untagged buffer keeps whatever the layer has: it makes no claim,
        // and re-deriving a space from nothing would flip the layer back and
        // forth on a source that tags some frames and not others
        guard let primaries = tagged as? NSString as CFString?,
              !CFEqual(primaries, installedPrimaries) else { return }
        let attachments = [
            kCVImageBufferColorPrimariesKey: primaries,
            kCVImageBufferTransferFunctionKey:
                kCVImageBufferTransferFunction_ITU_R_709_2,
            kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        ] as CFDictionary
        guard let space = CVImageBufferCreateColorSpaceFromAttachments(
            attachments)?.takeRetainedValue() else { return }
        installedPrimaries = primaries
        colorspace = space
    }

    /// The frame fitted into a `size` drawable. nil when the image has no
    /// extent to place.
    ///
    /// **Nothing about the operator's settings is applied here any more.** The
    /// exposure tools and the guides moved to the shared display stage first,
    /// so that the surfaces which are pixel buffers rather than layers — the
    /// hardware playout, the multiview, the phone grid — carry them too (owner
    /// item 7); the GEOMETRY followed, for exactly the same reason and one
    /// release later. A reframe that lived here was a reframe the director's
    /// monitor never saw.
    ///
    /// What is left is the fit, which genuinely is a property of this surface:
    /// the frame arriving is the SIGNAL's raster, already reframed inside it,
    /// and a window has to put that raster somewhere. An identity sizing is
    /// the whole of that — `placed` fits a source into a frame — so the fit,
    /// the integral-pixel placement and the fast paths stay stated once, in
    /// `PictureSizing`, rather than being written a second time here.
    /// Internal rather than private so the suite can render it and look:
    /// "this surface adds a fit and nothing else" is a claim about pixels, and
    /// the alternative is reading back a Metal drawable.
    func placedImage(from pixelBuffer: CVPixelBuffer,
                     in size: CGSize) -> CIImage? {
        let image = CIImage(cvPixelBuffer: pixelBuffer,
                            options: [.colorSpace: NSNull()])
        guard image.extent.width > 0, image.extent.height > 0 else { return nil }
        return PictureSizing().placed(image,
                                      in: CGRect(origin: .zero, size: size))
    }
}
