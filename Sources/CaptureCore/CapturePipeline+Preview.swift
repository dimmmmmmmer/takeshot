@preconcurrency import Accelerate
@preconcurrency import AVFoundation
@preconcurrency import CoreImage
@preconcurrency import CoreMedia
@preconcurrency import CoreVideo
import Foundation
import os.log

/// The display path: sinks, the pinned reference compare, LUT and levels
/// applied to what the operator sees.
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
    func compositeReference(_ reference: CVPixelBuffer,
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
    /// Tag a frame with colorimetry from settings if the backend didn't report it.
    /// Without tags the preview layer and the player interpret color differently.
    /// The values come from ColorTags — the same table the recorded file uses.
    /// NOTE: the buffer handed to the writer must keep standard tags — the
    /// encoder color-converts pixels when buffer tags mismatch the file tags
    /// (verified on device: a display-gamma tag here darkened recorded shadows).
    func tagColorIfUntagged(_ pixelBuffer: CVPixelBuffer) {
        guard CVBufferCopyAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey,
                                     nil) == nil else { return }
        ColorTags.tag(pixelBuffer, preset: config.settings.colorTagPreset)
    }
    /// Grab the next displayed frame as PNG (WYSIWYG with levels/preview LUT).
    /// The handler fires once, on the main queue.
    public func grabNextFrame(_ handler: @escaping @Sendable (Data?) -> Void) {
        queue.async { self.frameGrabHandler = handler }
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
    /// Run a frame through the LUT (CoreImage, GPU). nil — if no LUT set/on error.
    func applyLUT(to pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        guard let filter = lutFilter else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard let outBuffer = lutBufferPool.buffer(width: width, height: height) else {
            return nil
        }

        // raw code values on both ends: .cube LUTs are defined on gamma-encoded
        // codes, and the playback tap renders the same way — a color-managed
        // render here made live and playback diverge with the LUT on
        let input = CIImage(cvPixelBuffer: pixelBuffer,
                            options: [.colorSpace: NSNull()])
        filter.setValue(input, forKey: kCIInputImageKey)
        guard let output = filter.outputImage else { return nil }
        let finalImage = Self.mix(source: input, filtered: output,
                                  intensity: lutIntensity)
        let destination = CIRenderDestination(pixelBuffer: outBuffer)
        destination.colorSpace = nil
        // a failed render MUST NOT hand uninitialized pool memory to the writer
        guard let task = try? ciContext.startTask(toRender: finalImage,
                                                  to: destination),
              (try? task.waitUntilCompleted()) != nil else { return nil }
        tagColorIfUntagged(outBuffer)
        return outBuffer
    }
    /// Expand limited-range (16-235) RGB to full range, in place (vImage byte
    /// lookup — no CoreImage pass, no extra buffer). BGRA only: this is the
    /// single levels operation in the pipeline; the encoder handles full-RGB →
    /// legal-YUV for the file, and YUV sources are legal-range by definition.
    func expandLimitedRGB(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA
        else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        var image = vImage_Buffer(
            data: base,
            height: vImagePixelCount(CVPixelBufferGetHeight(pixelBuffer)),
            width: vImagePixelCount(CVPixelBufferGetWidth(pixelBuffer)),
            rowBytes: CVPixelBufferGetBytesPerRow(pixelBuffer))
        // byte order is B G R A: remap the three color channels, keep alpha
        let error = Self.levelsExpandTable.withUnsafeBufferPointer { lut in
            Self.levelsTableIdentity.withUnsafeBufferPointer { identity in
                vImageTableLookUp_ARGB8888(&image, &image,
                                           lut.baseAddress!, lut.baseAddress!,
                                           lut.baseAddress!, identity.baseAddress!,
                                           vImage_Flags(kvImageNoFlags))
            }
        }
        return error == kvImageNoError ? pixelBuffer : nil
    }
    /// Blend the original and LUT'd frame by intensity (cross-dissolve).
    public static func mix(source: CIImage, filtered: CIImage,
                           intensity: Double) -> CIImage {
        guard intensity < 0.999 else { return filtered }
        guard let dissolve = CIFilter(name: "CIDissolveTransition") else { return filtered }
        dissolve.setValue(source, forKey: "inputImage")
        dissolve.setValue(filtered, forKey: "inputTargetImage")
        dissolve.setValue(intensity, forKey: "inputTime")
        return dissolve.outputImage ?? filtered
    }
    /// The most recent processed preview frame (levels/LUT applied) — pulled by
    /// the playback tap for the compare modes. Thread-safe.
    public func currentPreviewBuffer() -> CVPixelBuffer? {
        latestPreviewLock.lock()
        defer { latestPreviewLock.unlock() }
        return latestPreview
    }
    /// `pixelBuffer` is the clean processed frame (compare provider, pinning);
    /// `screen` is what the preview sinks draw (may carry the reference wipe).
    func enqueuePreview(pixelBuffer: CVPixelBuffer,
                        screen: CVPixelBuffer? = nil) {
        latestPreviewLock.lock()
        latestPreview = pixelBuffer
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
