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
        guard !lutRecord else {
            let looked = lutPreview
                ? previewed : (applyLUT(to: display) ?? display)
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

    /// The key is being composited into a file that is actually open. Split from
    /// `bakesChromaKey` because that one answers "what will this take be", which
    /// the ring needs before a take exists, and this one answers "is there a
    /// frame to spend a GPU pass on".
    private var bakingIntoOpenTake: Bool {
        writer != nil && takeChromaRecord
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
