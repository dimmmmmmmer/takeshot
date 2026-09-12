@preconcurrency import CoreImage
@preconcurrency import CoreVideo
import Foundation

/// **The reframe, baked into the recording** (owner: "и то и другое, отдельной
/// галкой" — asked for BOTH: the geometry on every output, and a checkbox that
/// puts it in the file).
///
/// The default is off and the default is the whole feature next door: a sizing
/// is a VIEW, it reaches every surface that mirrors the viewer
/// (`AssistStage.rendered`), and the take stays what the camera sent. This file
/// is the operator saying otherwise for this shot.
///
/// # Why it is destructive, and why it is a checkbox
///
/// There is a non-destructive spelling of some of this — a QuickTime track
/// display matrix — and it is deliberately not used. It can carry the flips and
/// the right-angle rotations and nothing else: a matrix cannot CROP, so a zoom
/// above 1 would leave in the file exactly the footage the operator was
/// throwing away, and pan, tilt, pitch and yaw are unreachable without it. It
/// would also be a claim this app's own player cannot see —
/// `AVPlayerItemVideoOutput` ignores the matrix while every
/// `AVAssetImageGenerator` in the app honours it, so one take would sit rotated
/// in its poster and unrotated in the player beside it.
///
/// So the bake renders, and because it renders it costs the take its wire
/// codes: an 8-bit display buffer goes to the writer instead of the camera's
/// 10- or 12-bit ones. That is the same price the LUT bake and the key
/// composite already pay, it is why all three are one predicate
/// (`recordBakesDisplayBuffer`), and it is why the file says so — a take that
/// carries `TakeWriter.sizingKey` is not camera original and every reader of it
/// can find that out.
///
/// # The two rules it inherits
///
/// **Latched at `beginTake`.** The record buffer's pixel format follows this
/// answer and `AVAssetWriter` does not survive that changing under an open
/// session, so an operator who arms the bake mid-take bakes the NEXT one — the
/// defect `LUTBakeLatchTests` documents, avoided by construction.
///
/// **Never on the non-bake path.** With the checkbox off, `recordProduct`
/// hands the writer the wire-code buffer untouched; the sizing exists on the
/// display side only, and no test frame may find a resampled pixel in a file
/// nobody asked to reframe.
extension CapturePipeline {
    /// The operator's reframe, on both sides of the queue that needs it.
    ///
    /// `setChromaKey`'s shape exactly, and for its reason: this is called from
    /// `setViewAssist`, i.e. on every tick of every sizing slider in the app,
    /// and the hop onto the capture queue is taken ONLY when a bake is
    /// involved on one side of it or the other. An operator who is not baking
    /// pays nothing on the queue that appends to the writer, however hard they
    /// drag — and the tick that ARMS the bake carries the whole current
    /// geometry across, so the value latched at take open is never a stale one.
    func adoptSizing(_ sizing: PictureSizing, record: Bool) {
        chromaLock.lock()
        let bakedBefore = storedSizingRecord && !storedSizing.isIdentity
        storedSizing = sizing
        storedSizingRecord = record
        chromaLock.unlock()
        guard bakedBefore || (record && !sizing.isIdentity) else { return }
        queue.async { self.adoptRecordSizing(sizing, record: record) }
    }

    /// The capture queue's copy. The ring is dropped on the bake edge, for
    /// `dropPreRollOnFormatChange`'s reason: it holds what the writer gets.
    private func adoptRecordSizing(_ sizing: PictureSizing, record: Bool) {
        let was = recordBakesDisplayBuffer
        recordSizing = sizing
        sizingRecord = record
        sizingBufferPool.reset()
        dropPreRollOnFormatChange(was: was)
    }

    /// Whether the reframe is being rendered into the file right now.
    ///
    /// The LATCHED answer while a take is open and the armed one otherwise —
    /// `bakesLUT` and `bakesChromaKey`'s rule, and for their reason: what a
    /// rolling take does was settled at `beginTake`, and what an idle pipeline
    /// reports is what the NEXT take will do, which is what the pre-roll ring
    /// has to be holding by then.
    ///
    /// A reframe that does nothing is not a bake. `isIdentity` is what keeps a
    /// checkbox left on from last week from costing every take its wire codes
    /// for a transform that would have changed no pixel.
    var bakesSizing: Bool {
        guard writer == nil else { return takeSizingRecord }
        return sizingRecord && !recordSizing.isIdentity
    }

    /// The frame the writer gets when the reframe is baked in: the display
    /// buffer with the LATCHED geometry rendered into it.
    ///
    /// Only while a take is actually open, which is `chromaBaked`'s rule: with
    /// the bake armed and nothing rolling, the pass would be spent on a file
    /// that does not exist, and the ring is filling with frames the DRAIN will
    /// put through this same call with the same latched value.
    ///
    /// A failed render falls back to the unframed picture and is COUNTED, the
    /// answer the other two bakes give: a hole in the take is worse than a
    /// frame that is framed wrong, and a file that quietly lost content it
    /// claims to carry must leave a number behind.
    func sizingBaked(_ buffer: CVPixelBuffer) -> CVPixelBuffer {
        guard writer != nil, takeSizingRecord else { return buffer }
        return sizingRendered(buffer, using: takeSizing)
    }

    /// The same, for the pre-roll drain — the head of the take goes through
    /// the same bakes its body will, with the same latched values, or the file
    /// has a cut in the middle of it.
    func sizingBakedForDrain(_ buffer: CVPixelBuffer) -> CVPixelBuffer {
        sizingRendered(buffer, using: takeSizing)
    }

    /// One CoreImage pass, into a pool of this stage's own.
    ///
    /// **On the capture queue, synchronously**, like the LUT beside it and with
    /// the same stake: a slow pass here does not make a late picture, it makes
    /// a HOLE in the file. It is one resample of the raster — the same work the
    /// display stage does for every surface — and it is spent only on takes an
    /// operator asked to reframe.
    ///
    /// Black bars and not the operator's player background: the letterbox in a
    /// FILE is part of the deliverable, and the colour behind a picture in a
    /// window is a preference about a window.
    private func sizingRendered(_ buffer: CVPixelBuffer,
                                using sizing: PictureSizing) -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard let out = sizingBufferPool.buffer(width: width, height: height)
        else { return sizingBakeFailed(buffer) }
        let input = CIImage(cvPixelBuffer: buffer,
                            options: [.colorSpace: NSNull()])
        let framed = sizing.applied(
            to: input, in: CGRect(x: 0, y: 0, width: width, height: height),
            letterbox: CIColor(red: 0, green: 0, blue: 0))
        let destination = CIRenderDestination(pixelBuffer: out)
        destination.colorSpace = nil
        // a failed render MUST NOT hand uninitialized pool memory to the writer
        guard let task = try? ciContext.startTask(toRender: framed,
                                                  to: destination),
              (try? task.waitUntilCompleted()) != nil else {
            return sizingBakeFailed(buffer)
        }
        tagColorIfUntagged(out)
        return out
    }

    /// The frame goes in unframed and the failure leaves a number behind.
    private func sizingBakeFailed(_ buffer: CVPixelBuffer) -> CVPixelBuffer {
        chromaLock.lock()
        sizingBakeFallbackCount += 1
        chromaLock.unlock()
        return buffer
    }
}
