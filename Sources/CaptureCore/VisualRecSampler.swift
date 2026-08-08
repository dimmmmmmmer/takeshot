@preconcurrency import CoreVideo
import Foundation

/// Reads the taught box out of a display frame and reduces it to a signature.
///
/// Its own file so that `VisualRecTrigger`'s arithmetic stays free of CoreVideo
/// and can be reasoned about (and tested) on plain arrays — the same split
/// `ChromaKey` and `ChromaKeyer` have.
///
/// **8-bit BGRA only, and that is the point.** The trigger reads the display
/// buffer, one stage BEFORE the viewing LUT (see
/// `CapturePipeline.watchVisualRec`), which is the same stage the operator's
/// reference was captured from. A LUT switched on after the teaching is a look,
/// not a measurement, and it must not be able to move a take. Handed a wire
/// frame — 'r210', 'v210', 'R12B' — this answers nil rather than guessing at a
/// packing, because the display half is the only half a taught reference is ever
/// in.
///
/// **Constant cost, measured.** The tap count is fixed at `taps` × `taps`
/// whatever the region's size and whatever the signal's resolution — 1024 pixel
/// reads, three components each — so the pass costs the same at every raster,
/// and it does: sampler plus decision, in release, **0.004 ms at 1080p and
/// 0.004 ms at UHD**. Against the budget of one stride interval (200 ms at
/// 25 fps, see `CapturePipeline.visualRecUpdatesPerSecond`) that is four
/// thousandths of it, on a queue the capture path never waits for. For scale, the
/// scope analyzer's pass on the same machine is ~23 ms and is considered
/// affordable at 15 Hz.
public enum VisualRecSampler {
    /// Pixel taps per cell edge. Four, so every cell is the mean of 16 taps
    /// spread across it rather than one sample that a dead pixel or a JPEG-ish
    /// artefact can carry on its own.
    static let tapsPerCell = 4
    /// Taps per axis over the whole box.
    static let taps = VisualRecSignature.grid * tapsPerCell

    /// The signature of `region` in a display frame, or nil when the frame is
    /// not the 8-bit BGRA the display path produces, has no base address, or is
    /// degenerate.
    public static func signature(of buffer: CVPixelBuffer,
                                 region: VisualRecRegion) -> VisualRecSignature? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA
        else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard let box = region.pixels(width: width, height: height)
        else { return nil }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)

        let grid = VisualRecSignature.grid
        var sums = [Double](repeating: 0, count: VisualRecSignature.componentCount)
        for tapY in 0..<taps {
            // the tap grid is stretched over the box, so a wider box samples
            // more sparsely rather than more expensively
            let y = min(height - 1, box.y + tapY * box.height / taps)
            let row = bytes + y * rowBytes
            let cellRow = (tapY / tapsPerCell) * grid
            for tapX in 0..<taps {
                let x = min(width - 1, box.x + tapX * box.width / taps)
                let pixel = row + x * 4
                let cell = (cellRow + tapX / tapsPerCell) * 3
                // BGRA on the wire, R G B in the signature
                sums[cell] += Double(pixel[2])
                sums[cell + 1] += Double(pixel[1])
                sums[cell + 2] += Double(pixel[0])
            }
        }
        let perCell = Double(tapsPerCell * tapsPerCell)
        return VisualRecSignature(codes: sums.map { $0 / perCell })
    }
}
