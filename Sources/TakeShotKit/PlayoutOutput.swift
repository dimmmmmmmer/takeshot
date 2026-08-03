import CDeckLink
import CoreVideo
import Foundation

/// The hardware output the viewer is mirrored to.
///
/// A protocol for the same reason `CaptureBackend` is one on the input side: the
/// real conformer is `CDLPlayout`, whose init opens a DeckLink output on a board
/// the machine running the suite does not have — and if it does have one, opening
/// it puts this app's picture on somebody's monitor.
///
/// What is worth asserting about the mirror is all on this side of the line: that
/// a frame already in the output's raster and pixel format is handed over
/// untouched rather than copied, that one in any other geometry is aspect-fitted
/// into the output raster, and that a burst of frames is coalesced latest-wins
/// instead of queueing behind a 25 Hz output.
///
/// Threading: `display` is called only on the feeder's own serial queue.
protocol PlayoutOutput: AnyObject {
    var outputWidth: Int { get }
    var outputHeight: Int { get }
    /// Put one BGRA frame of exactly the output's geometry on the wire.
    @discardableResult
    func display(_ buffer: CVPixelBuffer) -> Bool
    func stop()
}

/// The real board. `CDLPlayout` already has the shape; this states it.
extension CDLPlayout: PlayoutOutput {
    var outputWidth: Int { Int(width) }
    var outputHeight: Int { Int(height) }

    @discardableResult
    func display(_ buffer: CVPixelBuffer) -> Bool {
        displayFrame(buffer)
    }
}
