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
///
/// The board sits behind `PlayoutOutput`, so everything above is drivable
/// without one — see the note there.
final class PlayoutFeeder: @unchecked Sendable {
    private let output: PlayoutOutput
    private let queue = DispatchQueue(label: "takeshot.playout",
                                      qos: .userInteractive)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let pool: PixelBufferPool
    private let lock = NSLock()
    private var pending: CVPixelBuffer?
    private var scheduled = false
    /// The last frame this feeder could not put on the board, if it is still
    /// failing. Queue-confined: only `display` touches it.
    ///
    /// **A monitor that freezes silently is the failure mode this exists for.**
    /// Both ways the scale can fail — no buffer out of the pool, CoreImage
    /// refusing the render — used to `return`, leaving the LAST frame on the
    /// board with nothing said. An operator judging framing on a picture that
    /// stopped being live is worse off than one looking at black, and the two
    /// look identical when the camera is on sticks.
    private var stallReason: String?

    /// Told once when the output stops taking frames, and once more when it
    /// starts again — never per frame, because this runs at the signal's rate.
    /// nil is the recovery.
    var onStall: (@Sendable (String?) -> Void)?

    /// How a feeder is built. Replaced by the suite so the controller's own
    /// routing (`rebuildPlayout`) can be driven with a fake board; never by the
    /// app. Main-actor state — `rebuildPlayout` is the only caller.
    @MainActor
    static var factory: (String, Int, Int, Double) throws -> PlayoutFeeder = {
        try PlayoutFeeder(deviceID: $0, width: $1, height: $2, frameRate: $3)
    }

    var outputSize: (width: Int, height: Int) {
        (output.outputWidth, output.outputHeight)
    }

    init(deviceID: String, width: Int, height: Int,
         frameRate: Double) throws {
        output = try CDLPlayout(deviceID: deviceID, width: Int32(width),
                                height: Int32(height), frameRate: frameRate)
        pool = PixelBufferPool()
    }

    init(output: PlayoutOutput) {
        self.output = output
        pool = PixelBufferPool()
    }

    func stop() {
        output.stop()
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

    /// Block until everything already submitted has been handled. The queue is
    /// private and `submit` is async onto it, so this is how a caller knows a
    /// frame has reached the output — the suite waits on this instead of a
    /// wall-clock window.
    func settle() {
        queue.sync {}
    }

    private func display(_ buffer: CVPixelBuffer) {
        let width = output.outputWidth
        let height = output.outputHeight
        if CVPixelBufferGetWidth(buffer) == width,
           CVPixelBufferGetHeight(buffer) == height,
           CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA {
            output.display(buffer)
            return
        }
        // geometry differs (e.g. UHD viewer on an HD output): aspect-fit
        guard let scaled = pool.buffer(width: width, height: height)
        else { return stall(L("playout_stalled_pool")) }
        let image = CIImage(cvPixelBuffer: buffer,
                            options: [.colorSpace: NSNull()])
        let fitted = CompareCompositor.fitted(
            image, into: CGRect(x: 0, y: 0, width: width, height: height))
        let destination = CIRenderDestination(pixelBuffer: scaled)
        destination.colorSpace = nil
        guard let task = try? context.startTask(toRender: fitted,
                                                to: destination),
              (try? task.waitUntilCompleted()) != nil else {
            return stall(L("playout_stalled_render"))
        }
        output.display(scaled)
        clearStall()
    }

    /// Say it once, on the way into a stall.
    private func stall(_ reason: String) {
        guard stallReason != reason else { return }
        stallReason = reason
        onStall?(reason)
    }

    /// …and once on the way out, so a row that went red goes back.
    private func clearStall() {
        guard stallReason != nil else { return }
        stallReason = nil
        onStall?(nil)
    }
}
