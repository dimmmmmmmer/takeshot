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
    public func setViewAssist(_ assist: ViewAssist) {
        displaySinks.setAssist(assist)
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
    /// `pixelBuffer` is the clean processed frame (compare provider, pinning);
    /// `preLUT` the same frame before the preview LUT (difference measures on
    /// it); `screen` is what the preview sinks draw (may carry the reference
    /// wipe).
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
        let schedule = !presentScheduled
        presentScheduled = true
        presentLock.unlock()
        guard schedule else { return } // a newer frame replaces the pending one
        displayQueue.async { [weak self] in
            guard let self else { return }
            self.presentLock.lock()
            let buffer = self.pendingPresent
            self.pendingPresent = nil
            self.presentScheduled = false
            self.presentLock.unlock()
            guard let buffer else { return }
            self.displaySinks.present(buffer)
            self.displayFrameLock.lock()
            let handler = self.displayFrameHandler
            self.displayFrameLock.unlock()
            handler?(buffer)
        }
    }
}
