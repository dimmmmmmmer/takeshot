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
    /// out of it: a monitoring surface is not an assist one, and every TOOL the
    /// operator switched on for themselves is wrong on it — the framing is not
    /// a tool and goes with it. See `enqueuePreview` for what that distinction
    /// costs and buys, and `LivePicture` for where it is stated.
    public func setOnMonitorFrame(_ handler: (@Sendable (LiveFrame) -> Void)?) {
        displayFrameLock.lock()
        monitorFrameHandler = handler
        displayFrameLock.unlock()
    }

    /// **Whether anything on the MIRRORS slot takes a picture built out of the
    /// clean one** — which is what decides whether the crew's framing pass is
    /// spent at all.
    ///
    /// The monitor slot always wants that picture; being wired at all is what
    /// says so. The mirrors are the hardware playout, NDI, SRT and whatever a
    /// browser picked, and the first three can only ever take `.decorated` —
    /// so an operator with a DeckLink out, an anamorphic desqueeze dialled in
    /// and no phones in the room would otherwise pay a full-raster CoreImage
    /// pass per frame for a buffer nobody reads. That is a third pass on a
    /// queue that already runs the keyer and the assist stage.
    ///
    /// A DEMAND question and not a second definition of what clean means: it
    /// is derived from the same encoder list the handler closure is built out
    /// of, in the same function, once per wiring
    /// (`CaptureController.wireDisplayMirrors`) — the rule this display path
    /// already follows for the frame rate beside it.
    public func setMirrorsTakeCleanPicture(_ takes: Bool) {
        displayFrameLock.lock()
        mirrorsTakeCleanPicture = takes
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
    /// …and whether the mirrors declared that they take the clean picture,
    /// which is the third of the same kind of claim: "a rig with a monitor out
    /// and no phones pays no framing pass" is a statement about this flag, and
    /// one left set from a previous wiring looks identical from outside.
    public var mirrorsTakeClean: Bool {
        displayFrameLock.lock()
        defer { displayFrameLock.unlock() }
        return mirrorsTakeCleanPicture
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
    /// multiview — owner item 7), and the geometry into the same frame one
    /// stage later, so that a reframe reaches those consumers too.
    ///
    /// **Nothing goes to the surfaces at all.** They used to be handed the
    /// whole value for the geometry half of it; that half is applied upstream
    /// now, and a layer aspect-fits what arrives.
    public func setViewAssist(_ assist: ViewAssist) {
        setChromaKey(assist.chroma)
        // …and the reframe, which the stage applies to every surface and the
        // capture queue bakes only if asked (`+Sizing`).
        adoptSizing(assist.sizing, record: assist.sizingRecord)
        assistStage.setAssist(assist)
        // A paused or signal-less surface gets no new frame to carry the
        // change, and everything this call changes is baked upstream — so the
        // last display frame is pushed through the stage again rather than
        // asking a surface to repaint a picture that cannot have changed.
        redrawDisplayStage()
    }

    /// Re-run the display stage over the frame already on screen. Used when an
    /// aid changes while nothing new is arriving.
    ///
    /// **Latest-wins, like `enqueuePreview`** — and it was not, which is what
    /// an operator felt as the app going treacly under a slider (owner: "лагает
    /// action safe, title safe"). A drag delivers about sixty changes a second
    /// and each one queued a FULL display pass: the chroma key, the assist
    /// stage and every sink, at the signal's raster. Sixty of those cannot
    /// finish in a second at UHD, so the queue grew for as long as the finger
    /// moved and the picture followed a second behind it.
    ///
    /// The REC-box sliders the same report named ("лагают и ползунки высоты и
    /// ширины") were cited here and do not come through this door at all — the
    /// box is not an aid and never reaches the assist stage. What was costing
    /// them is `VisualRecLiveState`, one publish per gesture instead of one per
    /// tick; naming them here made this look like their fix and left the real
    /// one unwritten for a round.
    ///
    /// Dropping the passes in between is safe here in a way it would not be for
    /// a FRAME: a redraw carries no picture of its own — it re-publishes
    /// whatever `lastDisplaySource` holds, with whatever `assistStage` holds —
    /// so the pass that does run reads the value the operator settled on. The
    /// flag is cleared at the START of the pass, so a change arriving mid-render
    /// schedules one more and the final value always lands.
    func redrawDisplayStage() {
        presentLock.lock()
        let schedule = !redrawScheduled
        redrawScheduled = true
        presentLock.unlock()
        guard schedule else { return } // one is already on its way
        displayQueue.async { [weak self] in
            guard let self else { return }
            self.presentLock.lock()
            self.redrawScheduled = false
            self.displayPassCounts.assistRedraws += 1
            self.presentLock.unlock()
            guard let buffer = self.lastDisplaySource else { return }
            // An aid changed, not the picture — so the pair is re-published as
            // it was. **Both halves and not the screen one twice**: the screen
            // buffer carries the pinned-reference wipe, and handing that to the
            // phones as their clean picture would put half of an hour-old frame
            // in a tile labelled A-cam every time a slider moved.
            self.publishDisplayFrame(buffer,
                                     clean: self.lastDisplayClean ?? buffer,
                                     deadline: .max)
        }
    }
    /// Wait until everything already scheduled on the display queue has run.
    ///
    /// For the suite: the queue is private and every publish is async onto it,
    /// so this is how a test knows a pass has finished without a wall-clock
    /// window — the same shape `PlayoutFeeder.settle` uses one target along.
    public func settleDisplay() {
        displayQueue.sync {}
    }

    public func setPreviewLetterbox(_ color: CIColor) {
        displaySinks.setLetterbox(color)
        // The stage as well as the surfaces: the bars around a REFRAMED
        // picture are inside the signal's raster and travel with the frame.
        assistStage.setLetterbox(color)
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
        let source = recordBakesDisplayBuffer ? recordBuffer : leveled
        // **Off the capture queue.** A full CoreImage render plus a PNG
        // deflate of a 1080p frame is milliseconds, and this queue holds the
        // writer, the pre-roll ring and the REC detector — one keypress
        // mid-take was one or more dropped frames on the queue that must not
        // be blocked. The playback arm of the same feature already does it
        // this way (`CaptureController+Stills`).
        //
        // The buffer is retained by the closure, which is what makes the hop
        // safe: the pools recycle, and a frame the encoder is done with can be
        // handed back out while this is still reading it.
        let context = ciContext
        let held = UncheckedSendable(source)
        Self.grabQueue.async {
            let png = Self.pngData(from: held.value, ciContext: context)
            DispatchQueue.main.async { grab(png) }
        }
    }

    /// Where a still is rendered and compressed. Its own queue rather than a
    /// global one so two grabs in quick succession cannot both be resident at
    /// once — a 1080p render holds a frame's worth of intermediate, and the
    /// machine's real job is writing ProRes.
    static let grabQueue = DispatchQueue(label: "com.takeshot.grab",
                                         qos: .userInitiated)

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
    /// picture a browser can choose. Every TOOL the operator switched on for
    /// themselves is wrong on those: a pinned-reference wipe would put half of
    /// an hour-old frame in a tile labelled A-cam, the chroma key would show
    /// the crew a background that is not in the shot, and false colour would
    /// tell them the scene is on fire. The settled FRAMING is not a tool and
    /// does go on it — `LivePicture.clean` says which part and why.
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
        lastDisplayClean = clean
        presentLock.lock()
        displayPassCounts.passes += 1
        presentLock.unlock()
        let keyed = self.chromaKeyed(buffer, deadline: deadline) ?? buffer
        let shown = assistStage.rendered(keyed, deadline: deadline) ?? keyed
        displaySinks.present(shown)
        displayFrameLock.lock()
        let mirrors = displayFrameHandler
        let monitors = monitorFrameHandler
        let wantsClean = monitors != nil || mirrorsTakeCleanPicture
        displayFrameLock.unlock()
        guard mirrors != nil || monitors != nil else { return }
        // **The crew's picture carries the FRAMING and none of the aids**
        // (owner: "на телефоне пусть тоже будет кадрирование") — see
        // `LivePicture.clean`, where what that picture IS is stated.
        //
        // Spent only when something actually takes it: the monitor slot always
        // does, and the mirrors say so through `setMirrorsTakeCleanPicture`.
        // A rig with a hardware monitor out and no phones in the room takes
        // `.decorated` and nothing else, and must not pay a full-raster pass
        // per frame for a buffer nobody reads.
        let frame = LiveFrame(
            decorated: shown,
            clean: wantsClean ? (assistStage.framed(clean) ?? clean) : clean)
        mirrors?(frame)
        monitors?(frame)
    }
}
