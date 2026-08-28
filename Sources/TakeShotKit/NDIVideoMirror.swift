@preconcurrency import CoreVideo
import Foundation

/// Mirrors the viewer to an NDI source, on a queue of its own.
///
/// **The one live output that is not a consumer of the shared encoder, and that
/// is a fact about NDI rather than a shortcut.** `SRTMirror` and
/// `WebRTCViewer` both register a sink on `LiveVideoEncoder` and take H.264
/// samples; NDI's SDK takes FRAMES and compresses them with a codec of its own
/// inside the send call, so forcing it through that seam would mean handing it
/// bytes it cannot use. It therefore hangs off the display buffer directly,
/// exactly as `PlayoutFeeder` does — the other consumer in this app that wants
/// pixels rather than a bitstream.
///
/// What that buys, and it is worth stating because it is the answer to "what do
/// two outputs at once cost": the two paths share nothing but the display
/// handler's dispatch. NDI's compression runs on `com.takeshot.ndi`, the shared
/// H.264 encode on `com.takeshot.encode`, and neither queue is ever behind the
/// other. A slow NDI receiver cannot stall a browser's picture, and an SRT
/// reconnect cannot stall NDI.
///
/// The discipline is `MultiviewEncoder`'s, `PlayoutFeeder`'s and
/// `LiveVideoEncoder`'s: the display queue drops a frame here and returns at
/// once, only the newest frame is kept, and the send runs on this queue — never
/// on capture, never on main. NDI's send is synchronous and compresses the frame
/// inside it, so it is real work; what keeps that off the paths that matter is
/// that it happens here and that a pass which cannot keep up REPLACES the
/// pending frame instead of queueing behind it. The feed falls to fewer frames
/// rather than to older ones, which is the right failure for a monitor.
///
/// **There is no pixel conversion, and that is the colour decision.** NDI's
/// uncompressed RGB formats carry full-range values with Rec.709 primaries and
/// transfer, which is byte for byte what the app's display buffer already holds
/// (the contract stated at `MetalPreviewLayer`). So the cheapest correct
/// conversion is none at all: the buffer goes to `CNDSender` as it arrived and
/// NDI reads its own base address at its own stride. No CoreImage anywhere in
/// this file, deliberately — the multiview encoder shipped a real bug of exactly
/// that kind, reading a pooled buffer with no colour space declared (CoreImage
/// guessed sRGB) and writing 709, which put a gamma conversion in a path that
/// was supposed to be an identity. A pass that does nothing cannot acquire one.
///
/// The mirror exists only while the setting is on: `CaptureController` builds it
/// on that edge and drops it on the other, and with it gone the display path has
/// no NDI consumer at all — an idle app pays nothing, exactly as the shared
/// encoder and the multiview encoder do.
final class NDIVideoMirror: @unchecked Sendable {
    /// Ceiling on the send rate. Not a throttle on any signal the app captures —
    /// every format it takes is at or under 60 — but the display path can
    /// republish far faster than a wire rate: an aid switched on over a paused
    /// picture pushes the same frame again (`CapturePipeline.redrawDisplayStage`),
    /// and a playback scrub delivers as fast as the decoder manages. Coalescing
    /// collapses those into one frame; the ceiling is what keeps a burst of them
    /// off the network. Deliberately the same number `LiveVideoEncoder` uses, so
    /// two outputs on one display frame are paced alike.
    static let framesPerSecond = 60.0

    static var minimumInterval: TimeInterval { 1 / framesPerSecond }

    /// The only pixel format the display path produces, and the one the sender's
    /// BGRX declaration is true of. A frame in anything else is dropped here,
    /// before it costs a queue hop.
    static let acceptedPixelFormat = kCVPixelFormatType_32BGRA

    /// The queue the send runs on. Named so a test can assert that the sender is
    /// never touched from the capture queue — or from the shared encoder's.
    static let queueLabel = "com.takeshot.ndi"

    private let queue = DispatchQueue(label: NDIVideoMirror.queueLabel,
                                      qos: .userInitiated)
    private let sender: NDISending
    /// Shortest gap between two sends (1 / the pace this mirror was built with).
    private let interval: TimeInterval

    // MARK: - queue-confined state

    /// Newest frame not yet sent, with the rate to state for it.
    private var pending: (buffer: CVPixelBuffer, rate: NDIFrameRate)?
    /// A send pass is already scheduled.
    private var scheduled = false
    /// When the last pass started, on the monotonic clock.
    private var lastSendAt: TimeInterval = 0
    /// `stop()` has run; late offers are inert.
    private var stopped = false

    init(sender: NDISending,
         framesPerSecond: Double = NDIVideoMirror.framesPerSecond) {
        self.sender = sender
        interval = framesPerSecond > 0 ? 1 / framesPerSecond
            : NDIVideoMirror.minimumInterval
    }

    /// Offer one displayed frame. Called on the display queue (live) or the tap
    /// queue (playback); returns at once — the hop is an async dispatch, never
    /// a wait.
    func offer(_ buffer: CVPixelBuffer, rate: NDIFrameRate) {
        guard CVPixelBufferGetPixelFormatType(buffer) == Self.acceptedPixelFormat
        else { return }
        queue.async { [self] in enqueue(buffer, rate: rate) }
    }

    private func enqueue(_ buffer: CVPixelBuffer, rate: NDIFrameRate) {
        guard !stopped else { return }
        pending = (buffer, rate) // latest wins
        guard !scheduled else { return }
        scheduled = true
        let now = RemoteServer.monotonicNow()
        let wait = max(0, lastSendAt + interval - now)
        queue.asyncAfter(deadline: .now() + wait) { [weak self] in
            self?.sendPending()
        }
    }

    private func sendPending() {
        scheduled = false
        guard !stopped, let frame = pending else { return }
        pending = nil
        // Stamped before the send, so the pace is measured start to start and a
        // slow send does not quietly raise the delivered rate afterwards.
        lastSendAt = RemoteServer.monotonicNow()
        sender.send(frame.buffer, rate: frame.rate)
    }

    /// Take the source off the network. Asynchronous on purpose: a send may be
    /// in flight and the main actor must not park behind it. The serial queue
    /// orders this after that send and before anything offered later, and
    /// `stopped` makes every one of those inert.
    func stop() {
        queue.async { [self] in
            stopped = true
            pending = nil
            sender.stop()
        }
    }
}
