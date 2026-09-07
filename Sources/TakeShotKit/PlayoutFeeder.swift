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
    /// What the board is doing, as the board answers it. Queue-confined: only
    /// `display` touches it.
    ///
    /// **A monitor that freezes silently is the failure mode this exists for.**
    /// Three ways a frame can fail to reach the wire — no buffer out of the
    /// pool, CoreImage refusing the render, and the board itself saying no —
    /// used to `return` or drop a `Bool`, leaving the LAST frame on the board
    /// with nothing said. An operator judging framing on a picture that stopped
    /// being live is worse off than one looking at black, and the two look
    /// identical when the camera is on sticks.
    private var state: PlayoutState = .opened

    /// Told on every CHANGE of that state and never per frame, because this
    /// runs at the signal's rate.
    var onState: (@Sendable (PlayoutState) -> Void)?

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
            // **The answer is read.** `CDLPlayout.displayFrame` returns NO when
            // the output has gone — most often because a second copy of this
            // app took the board — and dropping it counted a refused frame as
            // a shown one. This is the path a matched raster takes, which is
            // every frame on a correctly set up cart: the one place a silent
            // freeze was guaranteed to stay silent.
            report(output.display(buffer) ? .feeding
                                          : .stalled(L("playout_refused")))
            return
        }
        // geometry differs (e.g. UHD viewer on an HD output): aspect-fit
        guard let scaled = pool.buffer(width: width, height: height)
        else { return report(.stalled(L("playout_stalled_pool"))) }
        let image = CIImage(cvPixelBuffer: buffer,
                            options: [.colorSpace: NSNull()])
        let fitted = CompareCompositor.fitted(
            image, into: CGRect(x: 0, y: 0, width: width, height: height))
        let destination = CIRenderDestination(pixelBuffer: scaled)
        destination.colorSpace = nil
        guard let task = try? context.startTask(toRender: fitted,
                                                to: destination),
              (try? task.waitUntilCompleted()) != nil else {
            return report(.stalled(L("playout_stalled_render")))
        }
        report(output.display(scaled) ? .feeding : .stalled(L("playout_refused")))
    }

    /// Say it once, on every change — which is both halves of what the two
    /// separate `stall`/`clearStall` calls used to do, and, because the state
    /// is a value and not a nullable reason, one stall replacing a DIFFERENT
    /// stall is now a change too. It was not: a board that stopped taking
    /// frames while the pool was already empty kept saying the pool.
    private func report(_ next: PlayoutState) {
        guard state != next else { return }
        state = next
        onState?(next)
    }
}

/// What the hardware monitor output is doing, as the BOARD answers it.
///
/// The third of the three output states, beside `SRTOutputState` and
/// `NDIOutputState`, and honest in the same way: there is no case that means
/// "a board is selected in Settings". `feeding` is written when the hardware
/// took a frame and at no other time.
enum PlayoutState: Equatable {
    /// No board is selected, or the one that was is gone.
    case off
    /// The output is open and no frame has reached it yet.
    case opened
    /// The board took the last frame.
    case feeding
    /// It refused one, or the app could not make one for it.
    case stalled(String)
}
