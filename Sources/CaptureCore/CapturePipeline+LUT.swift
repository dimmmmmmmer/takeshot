@preconcurrency import CoreImage
@preconcurrency import CoreVideo
import Foundation

/// The viewing LUT: which of the two frames it lands on (preview, recording, or
/// both), and the CoreImage pass that applies it.
///
/// Split out of `+Frame` (which decided) and `+Preview` (which applied) — the
/// decision and the pass have to agree about the color domain they work in, and
/// they were two files apart. Kept separate from `+Levels` next door because
/// they are separate settings with separate failure modes: levels applied twice
/// vs a look baked into a deliverable.
extension CapturePipeline {
    /// What the LUT stage hands on: `display` feeds preview, scopes and grabs,
    /// `record` goes to the writer.
    struct FrameProducts {
        let display: CVPixelBuffer
        let record: CVPixelBuffer
    }

    /// LUT: preview may have the LUT while recording stays clean (or vice versa)
    func lutApplied(to leveled: LevelledFrame) -> FrameProducts {
        let display = leveled.display
        let displayBuffer = lutPreview
            ? (applyLUT(to: display) ?? display) : display
        return FrameProducts(display: displayBuffer,
                             record: recordProduct(leveled: leveled,
                                                   previewed: displayBuffer))
    }

    /// Which frame the writer gets.
    ///
    /// Baking is an 8-bit creative decision either way, so both bakes keep the
    /// BGRA display path; with neither of them on, the wire-code record buffer
    /// (10- or 12-bit) goes to the writer verbatim, which is the rule the whole
    /// colour pipeline rests on.
    ///
    /// The two bakes COMPOSE, in the order the monitor shows them: the LUT is a
    /// stage before the key, so a take that bakes both carries the look under the
    /// composite. A key baked with the LUT on preview only lands on the
    /// un-LUT'd frame — which is what two separate switches mean, and is the
    /// LUT's own established behaviour rather than something new here.
    private func recordProduct(leveled: LevelledFrame,
                               previewed: CVPixelBuffer) -> CVPixelBuffer {
        let display = leveled.display
        guard !bakesLUT else {
            let looked = recordLook(display, previewed: previewed)
            return bakingIntoOpenTake ? chromaBaked(looked) : looked
        }
        guard bakesChromaKey else { return leveled.wireRecord ?? display }
        // Armed but nothing is rolling: the format is already the display
        // buffer's (the pre-roll ring is filling with these frames), and the
        // composite itself would be a CoreImage pass on the capture queue for a
        // file that does not exist. The still grab reads this frame too, and
        // WYSIWYG for a grab means what the take would carry — with no take, the
        // camera.
        return bakingIntoOpenTake ? chromaBaked(display) : display
    }

    /// Whether the LUT is being baked into the file right now.
    ///
    /// The LATCHED answer while a take is open and the armed one otherwise,
    /// which is `bakesChromaKey`'s rule and for the same reason: what a rolling
    /// take does was settled at `beginTake` and cannot change under it, and what
    /// an idle pipeline reports is what the NEXT take will do — which is what
    /// the pre-roll ring has to be holding by then.
    var bakesLUT: Bool {
        guard writer == nil else { return takeLUTRecord }
        return lutRecord
    }

    /// The look the FILE gets, which is not always the look the monitor shows.
    ///
    /// The preview frame is reused when it already carries this exact filter,
    /// because that is the common case and a second CoreImage pass per frame is
    /// not free. An operator who swaps the LUT mid-take leaves the display
    /// carrying the new one while the file must keep the latched one — so
    /// identity is checked rather than assumed.
    private func recordLook(_ display: CVPixelBuffer,
                            previewed: CVPixelBuffer) -> CVPixelBuffer {
        let latched = writer == nil ? lutFilter : takeLUTFilter
        if lutPreview, latched === lutFilter { return previewed }
        return lutBakedOrCounted(display, using: latched)
    }

    /// The record-side bake, with its failure COUNTED.
    ///
    /// `applyLUT` answers nil for two different reasons: no filter latched —
    /// nothing to bake, the clean frame is right — and a render that failed
    /// (no pool buffer, no output image, a CoreImage task that did not
    /// complete). The second used to be `?? display` on both the live path and
    /// the pre-roll drain: the clean frame went into a file whose metadata says
    /// the look is baked, and nothing anywhere recorded that it happened. The
    /// chroma bake one file over counts exactly this — "content the file was
    /// supposed to carry and does not" — and a look is the same claim.
    func lutBakedOrCounted(_ buffer: CVPixelBuffer,
                           using chosen: CIFilter?) -> CVPixelBuffer {
        guard chosen != nil else { return buffer }
        if let baked = applyLUT(to: buffer, using: chosen) { return baked }
        chromaLock.lock()
        lutBakeFallbackCount += 1
        chromaLock.unlock()
        return buffer
    }

    /// The key is being composited into a file that is actually open. Split from
    /// `bakesChromaKey` because that one answers "what will this take be", which
    /// the ring needs before a take exists, and this one answers "is there a
    /// frame to spend a GPU pass on".
    private var bakingIntoOpenTake: Bool {
        writer != nil && takeChromaRecord
    }

    /// Run a frame through the LUT (CoreImage, GPU). nil — if no LUT set/on error.
    ///
    /// `using` defaults to the armed filter, which is what the preview wants.
    /// The RECORD path passes the take's latched filter instead, so a look
    /// swapped mid-take cannot reach a file that is already open.
    func applyLUT(to pixelBuffer: CVPixelBuffer,
                  using chosen: CIFilter? = nil) -> CVPixelBuffer? {
        guard let filter = chosen ?? lutFilter else { return nil }
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

    /// Blend the original and LUT'd frame by intensity (cross-dissolve).
    public static func mix(source: CIImage, filtered: CIImage,
                           intensity: Double) -> CIImage {
        // at full intensity, or with no dissolve filter to do it with, the
        // filtered frame already is the answer
        guard intensity < 0.999,
              let dissolve = CIFilter(name: "CIDissolveTransition")
        else { return filtered }
        dissolve.setValue(source, forKey: "inputImage")
        dissolve.setValue(filtered, forKey: "inputTargetImage")
        dissolve.setValue(intensity, forKey: "inputTime")
        return dissolve.outputImage ?? filtered
    }
}
