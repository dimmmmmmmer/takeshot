@preconcurrency import CoreImage
@preconcurrency import CoreVideo
import Foundation

/// The display path: the sinks a frame is handed to, the latest-wins hop that
/// gets it off the capture queue, and the still grab that rides along with it.
///
/// The pinned reference compare lives in `+Compare`, the levels and LUT applied
/// on the way here in `+Levels` and `+LUT`.
///
/// Split out of CapturePipeline, which had grown past 1300 lines.
extension CapturePipeline {
    public func setOnDisplayFrame(_ handler: (@Sendable (CVPixelBuffer) -> Void)?) {
        displayFrameLock.lock()
        displayFrameHandler = handler
        displayFrameLock.unlock()
    }
    /// The multiview mirror (see the handler's own comment in CapturePipeline).
    /// Called on the display queue, like the playout mirror — never on the
    /// capture queue.
    ///
    /// It is handed the CLEAN processed frame, not what the viewer draws: the
    /// camera grid on a phone is a monitoring surface, not an assist one. See
    /// `enqueuePreview` for what that distinction costs and buys.
    public func setOnMultiviewFrame(_ handler: (@Sendable (CVPixelBuffer) -> Void)?) {
        displayFrameLock.lock()
        multiviewFrameHandler = handler
        displayFrameLock.unlock()
    }
    public func addDisplaySink(_ layer: MetalPreviewLayer) {
        displaySinks.add(layer)
        // show the current frame right away — a paused/idle signal won't push
        // one; with no signal, blank the surface instead of letting the frame
        // of the previous source (playback) stick around
        if let buffer = currentPreviewBuffer() {
            layer.present(buffer)
        } else {
            layer.clearToBlack()
        }
    }
    public func removeDisplaySink(_ layer: MetalPreviewLayer) {
        displaySinks.remove(layer)
    }
    /// The operator aids, to every surface — and the chroma key out of the same
    /// value to the display stage, which is where it is applied (see
    /// `+ChromaKey` for why it cannot ride along inside the sinks).
    public func setViewAssist(_ assist: ViewAssist) {
        displaySinks.setAssist(assist)
        setChromaKey(assist.chroma)
    }
    public func setPreviewLetterbox(_ color: CIColor) {
        displaySinks.setLetterbox(color)
    }
    /// Grab the next displayed frame as PNG (WYSIWYG with levels/preview LUT).
    /// The handler fires once, on the main queue.
    public func grabNextFrame(_ handler: @escaping @Sendable (Data?) -> Void) {
        queue.async { self.frameGrabHandler = handler }
    }

    /// one-shot frame grab: stills are deliverables like the recording — the
    /// preview LUT is never baked in, only a look that is being recorded
    func serveFrameGrab(record recordBuffer: CVPixelBuffer,
                        leveled: CVPixelBuffer) {
        guard let grab = frameGrabHandler else { return }
        frameGrabHandler = nil
        // the clean 8-bit frame: CI can't read r210, and the record look
        // without a baked LUT IS the leveled frame
        let png = Self.pngData(from: lutRecord ? recordBuffer : leveled,
                               ciContext: ciContext)
        DispatchQueue.main.async { grab(png) }
    }

    public static func pngData(from pixelBuffer: CVPixelBuffer,
                               ciContext: CIContext) -> Data? {
        // identity conversion, PNG tagged with the same ICC "HDTV" (Rec.709)
        // space the preview and the ProRes decoder use — the still looks
        // exactly like the player in any color-managed viewer
        let attachments = [
            kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kCVImageBufferTransferFunctionKey: kCVImageBufferTransferFunction_ITU_R_709_2,
            kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        ] as CFDictionary
        let space = CVImageBufferCreateColorSpaceFromAttachments(attachments)?
            .takeRetainedValue()
            ?? CGColorSpace(name: CGColorSpace.itur_709)
            ?? CGColorSpaceCreateDeviceRGB()
        let image = CIImage(cvPixelBuffer: pixelBuffer,
                            options: [.colorSpace: space])
        return ciContext.pngRepresentation(of: image, format: .RGBA8,
                                           colorSpace: space)
    }

    /// The most recent processed preview frame (levels/LUT applied) — pulled by
    /// the playback tap for the compare modes. Thread-safe.
    public func currentPreviewBuffer() -> CVPixelBuffer? {
        latestPreviewLock.lock()
        defer { latestPreviewLock.unlock() }
        return latestPreview
    }
    /// The same frame at the pre-LUT stage (levels applied, preview LUT not) —
    /// pulled by the playback tap for the DIFFERENCE compare, which measures
    /// code values rather than showing the operator's look. Thread-safe.
    public func currentPreLUTPreviewBuffer() -> CVPixelBuffer? {
        latestPreviewLock.lock()
        defer { latestPreviewLock.unlock() }
        return latestPreLUT
    }
    /// `pixelBuffer` is the clean processed frame (compare provider, pinning,
    /// the multiview grid); `preLUT` the same frame before the preview LUT
    /// (difference measures on it); `screen` is what the preview sinks draw
    /// (may carry the reference wipe).
    func enqueuePreview(pixelBuffer: CVPixelBuffer,
                        preLUT: CVPixelBuffer? = nil,
                        screen: CVPixelBuffer? = nil) {
        latestPreviewLock.lock()
        latestPreview = pixelBuffer
        latestPreLUT = preLUT ?? pixelBuffer
        latestPreviewLock.unlock()
        let presented = screen ?? pixelBuffer
        presentLock.lock()
        pendingPresent = presented
        pendingClean = pixelBuffer
        pendingDeadline = displayDeadline()
        let schedule = !presentScheduled
        presentScheduled = true
        presentLock.unlock()
        guard schedule else { return } // a newer frame replaces the pending one
        displayQueue.async { [weak self] in
            guard let self else { return }
            self.presentLock.lock()
            let buffer = self.pendingPresent
            let clean = self.pendingClean
            let deadline = self.pendingDeadline
            self.pendingPresent = nil
            self.pendingClean = nil
            self.presentScheduled = false
            self.presentLock.unlock()
            guard let buffer else { return }
            // The last display-only stage, and the one the deliverables never
            // see: `pixelBuffer` above is already published clean for the
            // compare provider, and the grab was served from the untouched
            // frame back on the capture queue. What is keyed here is what the
            // OPERATOR'S surfaces get — the viewer and the hardware monitor —
            // which is the same rule the viewing LUT follows.
            let shown = self.chromaKeyed(buffer, deadline: deadline) ?? buffer
            self.displaySinks.present(shown)
            self.displayFrameLock.lock()
            let handler = self.displayFrameHandler
            let multiview = self.multiviewFrameHandler
            self.displayFrameLock.unlock()
            handler?(shown)
            // The camera grid on a phone gets the clean frame instead: it is a
            // monitoring surface, and everything the operator switches on for
            // themselves is wrong on it. The pinned-reference wipe would put
            // half of a frame from an hour ago in a tile labelled A-cam, and
            // the chroma-key preview would show the crew a composite of a
            // background that is not in the shot. The aids applied further
            // downstream — false colour, zebra, peaking, the punch-in crop —
            // never got this far in the first place: those live in
            // `MetalPreviewLayer`, per surface, and the grid is not one of its
            // surfaces. Tapping `shown` here was the one way any of that could
            // reach a phone, and it no longer does.
            multiview?(clean ?? buffer)
        }
    }
}
