import CoreMedia
@preconcurrency import CoreVideo
import Foundation
import os
import os.log

/// **One H.264 encode of the viewer, for every live consumer there is.**
///
/// This is the piece that was inside `SRTVideoMirror` while SRT was the only
/// thing watching, and the reason it is out here is arithmetic rather than
/// tidiness: a second consumer that built a second `VTCompressionSession` would
/// encode the same 1080p picture twice, on a machine whose actual job is
/// writing ProRes to a card. The encode is the expensive thing in this path —
/// everything downstream of it is byte shuffling — so it happens once and the
/// SAMPLE is what fans out.
///
/// Two consumers exist today and they want the same frame in two wire formats:
/// `SRTVideoMirror` puts it in a transport stream and `WebRTCViewer` puts it in
/// RTP. Both start from `MPEGTSMuxer.accessUnit(from:)`, which is the seam a
/// `CMSampleBuffer` becomes bytes at, and neither has an opinion the other has
/// to know about.
///
/// **The discipline is the one the mirror already had, unchanged.** The display
/// queue drops a frame here and returns at once; only the newest frame is kept;
/// the encode runs on THIS queue — never on capture, never on main. A pass that
/// cannot keep up REPLACES the pending frame instead of queueing behind it, so
/// the feed falls to fewer frames rather than to older ones, which is the right
/// failure for a monitor.
///
/// **The fan-out happens on VideoToolbox's own thread, deliberately.** Each sink
/// hops to whatever queue it owns — the mirror's socket queue, the viewer's RTP
/// queue — so the encoder's queue is never behind a socket, and the hop count
/// per frame is exactly what it was before this type existed.
///
/// Nothing here exists while nobody is watching: the controller builds one when
/// the first consumer appears and drops it when the last goes
/// (`CaptureController+WebRTC`, `CaptureController+SRT`).
final class LiveVideoEncoder: @unchecked Sendable {
    /// Ceiling on the encode rate. Not a throttle on any signal the app
    /// captures — every format it takes is at or under 60 — but the display
    /// path can republish far faster than a wire rate: an aid switched on over
    /// a paused picture pushes the same frame again
    /// (`CapturePipeline.redrawDisplayStage`), and a playback scrub delivers as
    /// fast as the decoder manages. Coalescing collapses those into one frame;
    /// the ceiling is what keeps a burst of them off the encoder.
    static let framesPerSecond = 60.0

    static var minimumInterval: TimeInterval { 1 / framesPerSecond }

    /// The only pixel format the display path produces. A frame in anything
    /// else is dropped here, before it costs a queue hop.
    static let acceptedPixelFormat = kCVPixelFormatType_32BGRA

    /// The queue everything runs on. Named so a test can assert that neither
    /// the encoder nor a socket is ever touched from the capture queue.
    static let queueLabel = "com.takeshot.encode"

    /// Frame rate to assume when nothing has said one. 1080p25 is what the
    /// playout mirror falls back to, for the same reason.
    static let fallbackFrameRate = 25

    /// One consumer's sample handler. Runs on VideoToolbox's thread; hop.
    typealias Sink = @Sendable (CMSampleBuffer) -> Void

    private let queue = DispatchQueue(label: LiveVideoEncoder.queueLabel,
                                      qos: .userInitiated)
    private let interval: TimeInterval
    /// What to say when VideoToolbox will not build a session at all. The one
    /// thing here an operator can be told about, so it goes where an operator
    /// is already looking — the SRT row (`CaptureController.applySRTEvent`).
    private let onFailure: @Sendable (String) -> Void

    /// The sinks, and the only state in this type that is NOT queue-confined:
    /// they are added and removed on the MainActor and read on VideoToolbox's
    /// thread, which is two threads and therefore a lock rather than a comment.
    private let sinks = OSAllocatedUnfairLock<[ObjectIdentifier: Sink]>(
        initialState: [:])

    // MARK: - queue-confined state

    private var encoder: SRTVideoEncoder?
    /// The rate a NEW session is built with. Not necessarily the rate the
    /// running one is at — see `setBitsPerSecond`.
    private var bitsPerSecond: Int
    private var pending: CVPixelBuffer?
    private var pendingFrameRate = 0.0
    private var scheduled = false
    private var stopped = false
    private var lastEncodeAt: TimeInterval = 0
    /// Monotonic clock at the first frame, and the last stamp handed to the
    /// encoder. The stream's clock is the app's own send clock: a monitoring
    /// feed's timing is when it went out, and the camera's timecode belongs to
    /// the file. 90 kHz, which is the transport stream's clock and RTP's alike.
    private var origin: TimeInterval?
    private var lastTicks: Int64 = -1

    init(bitsPerSecond: Int,
         framesPerSecond: Double = LiveVideoEncoder.framesPerSecond,
         onFailure: @escaping @Sendable (String) -> Void = { _ in }) {
        self.bitsPerSecond = bitsPerSecond
        self.onFailure = onFailure
        interval = framesPerSecond > 0 ? 1 / framesPerSecond
            : LiveVideoEncoder.minimumInterval
    }

    // MARK: - consumers

    /// Register a consumer. `owner` identifies it so the same object cannot
    /// register twice and so removal needs nothing but the object itself.
    func addSink(_ owner: AnyObject, _ sink: @escaping Sink) {
        // The key is taken OUT here: an `AnyObject` is not Sendable and the
        // locked closure is, so the identity crosses as a value rather than as
        // a reference nothing would be allowed to hold.
        let key = ObjectIdentifier(owner)
        sinks.withLock { $0[key] = sink }
    }

    func removeSink(_ owner: AnyObject) {
        let key = ObjectIdentifier(owner)
        sinks.withLock { _ = $0.removeValue(forKey: key) }
    }

    /// Whether anything is watching. The controller drops the whole encoder on
    /// this going false, which is what makes an idle set cost nothing.
    var hasSinks: Bool { sinks.withLock { !$0.isEmpty } }

    // MARK: - the operator's one dial

    /// Move the bitrate on the running session.
    ///
    /// **A rebuild would be the wrong answer and this is why the encoder grew
    /// `setBitsPerSecond` in the first place.** The rate is one number for one
    /// session and the session is now shared, so an operator turning the SRT
    /// bitrate down would otherwise cost every browser on the set a torn-down
    /// session and a fresh keyframe — a visible gap, for a number VideoToolbox
    /// takes while it runs. The session is left alone and only its rate moves.
    func setBitsPerSecond(_ rate: Int) {
        queue.async { [self] in
            guard !stopped, bitsPerSecond != rate else { return }
            bitsPerSecond = rate
            encoder?.setBitsPerSecond(rate)
        }
    }

    /// What the running session is actually set to, read back out of it; nil
    /// before the first frame, when there is no session yet.
    ///
    /// For the tests, like `RemoteServer.pinPressure`, and they need it: a dial
    /// that moved and a dial that only looks like it did are indistinguishable
    /// from outside, which is the whole reason `SRTVideoEncoder.appliedRate`
    /// exists one layer down.
    var appliedBitsPerSecond: Int? { queue.sync { encoder?.bitsPerSecond } }

    // MARK: - the frame path

    /// Offer one displayed frame. Called on the display queue (live) or the tap
    /// queue (playback); returns at once — the hop is an async dispatch, never
    /// a wait.
    func offer(_ buffer: CVPixelBuffer, framesPerSecond: Double) {
        guard CVPixelBufferGetPixelFormatType(buffer) == Self.acceptedPixelFormat
        else { return }
        queue.async { [self] in enqueue(buffer, framesPerSecond: framesPerSecond) }
    }

    /// Ask for a keyframe on the next frame encoded.
    ///
    /// The reason `SRTVideoEncoder.requestKeyframe` exists, and it has two
    /// callers now: a WebRTC viewer that has just joined sees nothing until one
    /// arrives, and an SRT link that has just reopened is a new receiver as far
    /// as anything downstream knows. Repeated asks collapse into one — a room
    /// of phones joining at once wants one keyframe between them.
    func requestKeyframe() {
        queue.async { [self] in encoder?.requestKeyframe() }
    }

    /// Tear the session down. Asynchronous on purpose: an encode may be in
    /// flight and the MainActor must not park behind it.
    func stop() {
        queue.async { [self] in
            stopped = true
            pending = nil
            encoder?.invalidate()
            encoder = nil
        }
        sinks.withLock { $0.removeAll() }
    }

    private func enqueue(_ buffer: CVPixelBuffer, framesPerSecond: Double) {
        guard !stopped else { return }
        pending = buffer // latest wins
        pendingFrameRate = framesPerSecond
        guard !scheduled else { return }
        scheduled = true
        let wait = max(0, lastEncodeAt + interval - RemoteServer.monotonicNow())
        queue.asyncAfter(deadline: .now() + wait) { [weak self] in
            self?.encodePending()
        }
    }

    private func encodePending() {
        scheduled = false
        guard !stopped, let buffer = pending else { return }
        pending = nil
        // Nobody watching: the frame is dropped here rather than compressed for
        // no one. An SRT link between reconnects removes its sink, so an idle
        // reconnect costs one buffer release per frame interval and no encode.
        guard hasSinks else { return }
        // Stamped before the pass, so the pace is measured start to start and a
        // slow encode does not quietly raise the delivered rate afterwards.
        lastEncodeAt = RemoteServer.monotonicNow()
        guard let session = session(for: buffer) else { return }
        session.encode(buffer, ticks: nextTicks(at: lastEncodeAt))
    }

    /// The 90 kHz stamp for a frame offered at `now`, forced to increase — the
    /// encoder rejects a timestamp that does not, and two frames closer
    /// together than 11 µs cannot happen under the pace ceiling anyway.
    private func nextTicks(at now: TimeInterval) -> Int64 {
        let start = origin ?? now
        origin = start
        let ticks = Int64((now - start) * Double(MPEGTSMuxer.clockHz))
        lastTicks = max(ticks, lastTicks + 1)
        return lastTicks
    }

    /// An encoder built for this raster and rate, rebuilt when either changes.
    ///
    /// A rebuild is what a signal format change or a switch into playback
    /// costs, and it is deliberately not smoothed over: the new session's first
    /// frame is a keyframe, which drags the parameter sets and the tables with
    /// it, so every receiver follows the change instead of decoding the new
    /// raster against the old SPS.
    private func session(for buffer: CVPixelBuffer) -> SRTVideoEncoder? {
        let rate = pendingFrameRate > 0
            ? Int(pendingFrameRate.rounded()) : Self.fallbackFrameRate
        let wanted = SRTVideoEncoder.Configuration(
            width: CVPixelBufferGetWidth(buffer),
            height: CVPixelBufferGetHeight(buffer),
            framesPerSecond: max(1, rate), bitsPerSecond: bitsPerSecond)
        // The RASTER and the rate, and deliberately not the bitrate: that one
        // moves on a running session (`setBitsPerSecond`), so comparing it here
        // would rebuild for a number VideoToolbox would have taken live — and
        // a rebuild is a gap and a keyframe for every consumer at once.
        if let encoder, encoder.configuration.width == wanted.width,
           encoder.configuration.height == wanted.height,
           encoder.configuration.framesPerSecond == wanted.framesPerSecond {
            return encoder
        }
        encoder?.invalidate()
        encoder = nil
        do {
            encoder = try SRTVideoEncoder(configuration: wanted) { [weak self] sample in
                // VideoToolbox's queue. Every sink hops to its own from here,
                // which is why this closure does not touch a single piece of
                // this object's queue-confined state.
                self?.deliver(sample)
            }
        } catch {
            onFailure((error as? SRTStreamError)?.message
                ?? error.localizedDescription)
        }
        if let refused = encoder?.refusedProperties, !refused.isEmpty {
            // Not a failure: the stream still encodes, at VideoToolbox's own
            // defaults for whatever was refused. It IS the operator's bitrate
            // quietly not being honoured, so it goes where a number nobody
            // watches live belongs — the log a diagnostics bundle carries.
            os_log("live encoder refused %{public}s",
                   refused.joined(separator: ", "))
        }
        return encoder
    }

    /// One encoded sample to every consumer. The dictionary is copied out under
    /// the lock and walked outside it: a sink that removes itself from inside
    /// its own callback would otherwise deadlock, and a sink is allowed to.
    private func deliver(_ sample: CMSampleBuffer) {
        for sink in sinks.withLock({ Array($0.values) }) { sink(sample) }
    }
}
