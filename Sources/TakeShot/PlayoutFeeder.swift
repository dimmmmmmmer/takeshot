import CDeckLink
import CaptureCore
import CoreImage
import CoreVideo
import Foundation

/// Mirrors the viewer to a DeckLink output. Frames arrive from the pipeline's
/// display queue (live) or the tap queue (playback); submission is coalesced
/// latest-wins on a private queue, and frames whose geometry differs from the
/// output mode are aspect-fitted through CoreImage (unmanaged code values —
/// the hardware output shows the same pixels as the on-screen viewer).
final class PlayoutFeeder: @unchecked Sendable {
    private let playout: CDLPlayout
    private let queue = DispatchQueue(label: "takeshot.playout",
                                      qos: .userInteractive)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let pool: PixelBufferPool
    private let lock = NSLock()
    private var pending: CVPixelBuffer?
    private var scheduled = false

    var outputSize: (width: Int, height: Int) {
        (Int(playout.width), Int(playout.height))
    }

    init(deviceID: String, width: Int, height: Int,
         frameRate: Double) throws {
        playout = try CDLPlayout(deviceID: deviceID, width: Int32(width),
                                 height: Int32(height), frameRate: frameRate)
        pool = PixelBufferPool()
    }

    func stop() {
        playout.stop()
    }

    /// Hand the newest viewer frame to the output (any queue).
    func submit(_ buffer: CVPixelBuffer) {
        lock.lock()
        pending = buffer
        let schedule = !scheduled
        scheduled = true
        lock.unlock()
        guard schedule else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let buffer = self.pending
            self.pending = nil
            self.scheduled = false
            self.lock.unlock()
            guard let buffer else { return }
            self.display(buffer)
        }
    }

    private func display(_ buffer: CVPixelBuffer) {
        let width = Int(playout.width)
        let height = Int(playout.height)
        if CVPixelBufferGetWidth(buffer) == width,
           CVPixelBufferGetHeight(buffer) == height,
           CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA {
            playout.displayFrame(buffer)
            return
        }
        // geometry differs (e.g. UHD viewer on an HD output): aspect-fit
        guard let scaled = pool.buffer(width: width, height: height)
        else { return }
        let image = CIImage(cvPixelBuffer: buffer,
                            options: [.colorSpace: NSNull()])
        let fitted = CompareCompositor.fitted(
            image, into: CGRect(x: 0, y: 0, width: width, height: height))
        let destination = CIRenderDestination(pixelBuffer: scaled)
        destination.colorSpace = nil
        guard let task = try? context.startTask(toRender: fitted,
                                                to: destination),
              (try? task.waitUntilCompleted()) != nil else { return }
        playout.displayFrame(scaled)
    }
}
