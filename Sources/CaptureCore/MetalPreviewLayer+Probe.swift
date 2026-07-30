@preconcurrency import CoreVideo
import os.log

/// The rec-vs-playback parity probe: with `debugTag` set, every ~50th presented
/// frame is sampled into the unified log so two surfaces showing the same
/// picture can be compared code value by code value.
///
/// Split out of `+Render`: this is instrumentation that reads a frame, not part
/// of drawing one, and the draw path is easier to follow without 30 lines of
/// pixel sampling in the middle of it. Internal rather than private — `render()`
/// calls it from the other file.
extension MetalPreviewLayer {
    /// Parity debugging between surfaces (rec vs playback): with `debugTag`
    /// set, the center pixel of every ~50th presented frame goes to the
    /// unified log. Call under renderLock — `presentCount` is bumped here.
    func logProbeIfTagged(_ pixelBuffer: CVPixelBuffer) {
        guard let debugTag else { return }
        presentCount += 1
        guard presentCount % 50 == 1,
              CVPixelBufferGetPixelFormatType(pixelBuffer)
                  == kCVPixelFormatType_32BGRA else { return }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        let bpr = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let p = bytes + (h / 2) * bpr + (w / 2) * 4
        // 16x16 grid mean: catches a global shift in any tonal
        // zone, not just whatever sits under the center pixel
        var sumR = 0, sumG = 0, sumB = 0
        for gy in 0..<16 {
            let row = bytes + ((gy * 2 + 1) * h / 32) * bpr
            for gx in 0..<16 {
                let q = row + ((gx * 2 + 1) * w / 32) * 4
                sumB += Int(q[0]); sumG += Int(q[1]); sumR += Int(q[2])
            }
        }
        os_log("probe %{public}s %dx%d center=(%d,%d,%d) mean=(%d,%d,%d)",
               log: CapturePipeline.levelsLog, type: .default,
               debugTag, w, h, p[2], p[1], p[0],
               sumR / 256, sumG / 256, sumB / 256)
    }
}
