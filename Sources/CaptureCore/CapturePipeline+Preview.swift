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
    public func setOnDisplayFrame(_ handler: (@Sendable (LiveFrame) -> Void)?) {
        displayFrameLock.lock()
        displayFrameHandler = handler
        displayFrameLock.unlock()
    }
    /// The crew monitoring mirror (see the handler's own comment in
    /// CapturePipeline). Called on the display queue, like the playout mirror —
    /// never on the capture queue.
    ///
    /// Whoever rides this slot wants `LivePicture.clean` or the `.grid` built
    /// out of it: a monitoring surface is not an assist one, and everything the
    /// operator switched on for themselves is wrong on it. See `enqueuePreview`
    /// for what that distinction costs and buys, and `LivePicture` for where it
    /// is stated.
    public func setOnMonitorFrame(_ handler: (@Sendable (LiveFrame) -> Void)?) {
        displayFrameLock.lock()
        monitorFrameHandler = handler
        displayFrameLock.unlock()
    }
    /// Whether anything is taking the viewer's mirrors, and whether anything is
    /// taking the monitor picture.
    ///
    /// For the tests, and they need them: "an idle app costs nothing per frame"
    /// is a claim about these two slots being EMPTY, and a slot that was never
    /// cleared and one that was are indistinguishable from outside otherwise —
    /// the app looks identical and pays a closure call and a `LiveFrame` per
    /// frame for the rest of the shift.
    public var publishesDisplayFrames: Bool {
        displayFrameLock.lock()
        defer { displayFrameLock.unlock() }
        return displayFrameHandler != nil
    }
    public var publishesMonitorFrames: Bool {
        displayFrameLock.lock()
        defer { displayFrameLock.unlock() }
        return monitorFrameHandler != nil
    }
    public func addDisplaySink(_ layer: MetalPreviewLayer) {
        displaySinks.add(layer)
        // show the current frame right away — a paused/idle signal won't push
        // one; with no signal, blank the surface instead of letting the frame
        // of the previous source (playback) stick around
        if let buffer = currentPreviewBuffer() {
            layer.present(buffer)
            // …and then the same frame decorated: a window opened while a
            // false colour is on must not sit on the plain picture until the
            // next frame arrives, and a paused signal has no next frame.
            redrawDisplayStage()
        } else {
            layer.clearToBlack()
        }
    }
    public func removeDisplaySink(_ layer: MetalPreviewLayer) {
        displaySinks.remove(layer)
    }
    /// The operator aids. The value goes three ways out of one call, because
    /// its three halves are applied at three different stages: the chroma key
    /// before the aids, the exposure tools and the guides into the display
    /// frame itself (which is what carries them to the playout and the
    /// multiview — owner item 7), and the whole value on to the sinks, which
    /// use only the geometry in it.
    public func setViewAssist(_ assist: ViewAssist) {
        setChromaKey(assist.chroma)
        assistStage.setAssist(assist)
        displaySinks.setAssist(assist)
        // A paused or signal-less surface gets no new frame to carry the
        // change, so the sinks re-render the one they are holding themselves
        // (`MetalPreviewLayer.setAssist`) — but that redraw would now show the
        // aids from BEFORE this call, because they are baked upstream. Push the
        // last display frame through the stage again instead.
        redrawDisplayStage()
    }

    /// Re-run the display stage over the frame already on screen. Used when an
    /// aid changes while nothing new is arriving.
    func redrawDisplayStage() {
        displayQueue.async { [weak self] in
            guard let self, let buffer = self.lastDisplaySource else { return }
            // An aid changed, not the picture: the grid's frame is the one it
            // already has, so re-publishing the same source as its own clean
            // copy leaves the phones exactly where they were.
            self.publishDisplayFrame(buffer, clean: buffer, deadline: .max)
        }
    }
    public func setPreviewLetterbox(_ color: CIColor) {
        displaySinks.setLetterbox(color)
    }
    /// Grab the next displayed frame as PNG (WYSIWYG with levels/preview LUT).
    /// The handler fires once, on the main queue.
    public func grabNextFrame(_ handler: @escaping @Sendable (Data?) -> Void) {
        queue.async { self.frameGrabHandler = handler }
    }

    /// one-shot frame grab: stills are deliverables like the recording — a
    /// display decision is never baked in, only one that is being recorded
    func serveFrameGrab(record recordBuffer: CVPixelBuffer,
                        leveled: CVPixelBuffer) {
        guard let grab = frameGrabHandler else { return }
        frameGrabHandler = nil
        // the clean 8-bit frame: CI can't read r210, and the record look with
        // nothing baked in IS the leveled frame. With a bake on, the grab is
        // the take's own picture — including the chroma composite while a take
        // is rolling, and the camera's picture when none is (there is then no
        // deliverable for the still to match, and no pass has been spent).
        let png = Self.pngData(from: recordBakesDisplayBuffer
                                   ? recordBuffer : leveled,
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
            self.publishDisplayFrame(buffer, clean: clean ?? buffer,
                                     deadline: deadline)
        }
    }

    /// The last display-only stages, and the surfaces that get their result.
    ///
    /// By the time this runs the frame has already been written, grabbed and
    /// measured: `enqueuePreview` published the CLEAN buffer for the compare
    /// provider, and the writer, the grab and the scopes were all served back
    /// on the capture queue (see `+Frame` for the order). What is decorated
    /// here is what the MIRRORS get — the viewer, the director's monitor, the
    /// hardware output — which is the rule the viewing LUT and the chroma key
    /// already follow. The deliverables never see any of it.
    ///
    /// Key first, aids second: a false colour has to meter the picture the
    /// monitor is actually showing, background and all.
    ///
    /// `clean` is that same frame before the key and the aids, and it is what a
    /// MONITORING surface gets — the phone's camera grid, and the composed grid
    /// picture a browser can choose. Everything the operator switched on for
    /// themselves is wrong on those: a pinned-reference wipe would put half of
    /// an hour-old frame in a tile labelled A-cam, the chroma key would show
    /// the crew a background that is not in the shot, and false colour would
    /// tell them the scene is on fire.
    ///
    /// **The two pictures leave here as one value.** Which of them any given
    /// consumer takes is stated by naming a `LivePicture`, and `LiveFrame`'s
    /// subscript is the only place a name becomes a buffer — so a browser
    /// asking for the clean picture and the phone grid cannot end up with two
    /// readings of what clean means. The pair is built only when somebody is
    /// there to take it: with both slots empty this returns before it exists.
    ///
    /// Display-queue only.
    func publishDisplayFrame(_ buffer: CVPixelBuffer, clean: CVPixelBuffer,
                             deadline: UInt64) {
        lastDisplaySource = buffer
        let keyed = self.chromaKeyed(buffer, deadline: deadline) ?? buffer
        let shown = assistStage.rendered(keyed, deadline: deadline) ?? keyed
        displaySinks.present(shown)
        displayFrameLock.lock()
        let mirrors = displayFrameHandler
        let monitors = monitorFrameHandler
        displayFrameLock.unlock()
        guard mirrors != nil || monitors != nil else { return }
        let frame = LiveFrame(decorated: shown, clean: clean)
        mirrors?(frame)
        monitors?(frame)
    }
}
