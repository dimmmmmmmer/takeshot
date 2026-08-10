import CaptureCore
import CoreMedia
@preconcurrency import CoreVideo
import Foundation
import os.log

/// Mirrors the viewer to an SRT endpoint, on a queue of its own.
///
/// The discipline is `MultiviewEncoder`'s and `PlayoutFeeder`'s, and it has to be
/// stricter here than it was for NDI because there is real work in the path: the
/// display queue drops a frame here and returns at once, only the newest frame is
/// kept, and the encode, the mux and the send all run on THIS queue — never on
/// capture, never on main. A pass that cannot keep up REPLACES the pending frame
/// instead of queueing behind it, so the feed falls to fewer frames rather than to
/// older ones, which is the right failure for a monitor.
///
/// **Nothing in this path can block the frame path, by construction rather than by
/// being fast.** `offer` is a pixel-format test and one `dispatch_async`. The
/// encode is asked to drop quality rather than take longer. The socket is opened
/// with sending asynchronous, so a link that cannot take the bytes says "again"
/// and the datagram is dropped. And a connect — the one call here that really can
/// park for seconds — happens on this queue, where parking costs frames on a
/// monitor and nothing else.
///
/// **A dead link is the normal case, so it is a state and not an error.** On a
/// venue network the receiver is closed half the day, the Wi-Fi drops, somebody
/// re-patches a switch. The link is reopened with a backoff, the operator is told
/// once, and nothing here can reach the recorder: the whole file calls the
/// display path's frames and a socket, and neither the pipeline nor the writer
/// appears in it.
final class SRTVideoMirror: @unchecked Sendable {
    /// What the operator is told, hopped to the MainActor by the controller.
    enum Event: Equatable, Sendable {
        /// Datagrams are going out and the link is taking them.
        case opened
        /// Nothing is going yet and nothing is wrong: a listener with no receiver
        /// dialled in.
        case waiting
        /// A retryable failure — the far end is not there, or it went away.
        /// Carries what libsrt said; a reconnect is already scheduled.
        case lost(String)
        /// It will not open until the operator changes something.
        case refused(String)
        /// This build or this machine cannot send at all.
        case unavailable(String)
    }

    /// Ceiling on the send rate. Not a throttle on any signal the app captures —
    /// every format it takes is at or under 60 — but the display path can
    /// republish far faster than a wire rate: an aid switched on over a paused
    /// picture pushes the same frame again (`CapturePipeline.redrawDisplayStage`),
    /// and a playback scrub delivers as fast as the decoder manages. Coalescing
    /// collapses those into one frame; the ceiling is what keeps a burst of them
    /// off the encoder and off the network.
    static let framesPerSecond = 60.0

    static var minimumInterval: TimeInterval { 1 / framesPerSecond }

    /// The only pixel format the display path produces. A frame in anything else
    /// is dropped here, before it costs a queue hop.
    static let acceptedPixelFormat = kCVPixelFormatType_32BGRA

    /// The queue everything runs on. Named so a test can assert that neither the
    /// encoder nor the socket is ever touched from the capture queue.
    static let queueLabel = "com.takeshot.srt"

    /// First wait after a link goes, and the ceiling it doubles up to.
    ///
    /// A second is short enough that a receiver reopened by hand comes back while
    /// the operator is still looking at the screen; five is slow enough that a
    /// venue network that is simply not there costs one connect attempt per five
    /// seconds rather than a busy queue.
    static let reconnectDelay: TimeInterval = 1
    static let reconnectCeiling: TimeInterval = 5

    /// Rate the dropped-datagram count is logged at.
    ///
    /// Logged and not shown. A link that cannot carry the bitrate drops
    /// datagrams steadily, and the two things that fix it — the bitrate and the
    /// latency — are already the fields in front of the operator; a counter
    /// ticking in the settings window would re-render it every frame and tell
    /// them nothing they can act on faster. The log excerpt in a diagnostics
    /// bundle is where a number nobody watches live belongs.
    static let dropLogInterval = 100

    /// Frame rate to assume when nothing has said one. 1080p25 is what the
    /// playout mirror falls back to, for the same reason.
    static let fallbackFrameRate = 25

    private let queue = DispatchQueue(label: SRTVideoMirror.queueLabel,
                                      qos: .userInitiated)
    private let endpoint: SRTEndpoint
    private let bitsPerSecond: Int
    private let factory: @Sendable (SRTEndpoint) throws -> SRTStreamSending
    private let onEvent: @Sendable (Event) -> Void
    private let interval: TimeInterval

    // MARK: - queue-confined state

    private var stream: SRTStreamSending?
    private var muxer = MPEGTSMuxer()
    private var encoder: SRTVideoEncoder?
    private var pending: CVPixelBuffer?
    private var pendingFrameRate = 0.0
    private var scheduled = false
    private var reopening = false
    private var stopped = false
    private var lastSendAt: TimeInterval = 0
    private var backoff = SRTVideoMirror.reconnectDelay
    /// Monotonic clock at the first frame, and the last stamp handed to the
    /// encoder. The stream's clock is the app's own send clock: a monitoring
    /// feed's timing is when it went out, and the camera's timecode belongs to
    /// the file.
    private var origin: TimeInterval?
    private var lastTicks: Int64 = -1
    private var dropped = 0
    /// The last event handed upwards. A repeat is swallowed: each one is a
    /// MainActor hop and a `@Published` write, and "still reconnecting" arriving
    /// once a second would re-render the settings window for no news.
    private var reported: Event?

    init(endpoint: SRTEndpoint, bitsPerSecond: Int,
         framesPerSecond: Double = SRTVideoMirror.framesPerSecond,
         factory: @escaping @Sendable (SRTEndpoint) throws -> SRTStreamSending,
         onEvent: @escaping @Sendable (Event) -> Void) {
        self.endpoint = endpoint
        self.bitsPerSecond = bitsPerSecond
        self.factory = factory
        self.onEvent = onEvent
        interval = framesPerSecond > 0 ? 1 / framesPerSecond
            : SRTVideoMirror.minimumInterval
    }

    /// Open the link. Asynchronous on purpose: a caller's connect blocks, and the
    /// MainActor must not be the thread it blocks.
    func start() {
        queue.async { [self] in openLink() }
    }

    /// Offer one displayed frame. Called on the display queue (live) or the tap
    /// queue (playback); returns at once — the hop is an async dispatch, never a
    /// wait.
    func offer(_ buffer: CVPixelBuffer, framesPerSecond: Double) {
        guard CVPixelBufferGetPixelFormatType(buffer) == Self.acceptedPixelFormat
        else { return }
        queue.async { [self] in enqueue(buffer, framesPerSecond: framesPerSecond) }
    }

    /// Take the link down. Asynchronous on purpose: a send or a connect may be in
    /// flight and the main actor must not park behind it. The serial queue orders
    /// this after that call and before anything offered later, and `stopped` makes
    /// every one of those inert.
    func stop() {
        queue.async { [self] in
            stopped = true
            pending = nil
            encoder?.invalidate()
            encoder = nil
            stream?.close()
            stream = nil
        }
    }

    // MARK: - the frame path

    private func enqueue(_ buffer: CVPixelBuffer, framesPerSecond: Double) {
        guard !stopped else { return }
        pending = buffer // latest wins
        pendingFrameRate = framesPerSecond
        guard !scheduled else { return }
        scheduled = true
        let wait = max(0, lastSendAt + interval - RemoteServer.monotonicNow())
        queue.asyncAfter(deadline: .now() + wait) { [weak self] in
            self?.encodePending()
        }
    }

    private func encodePending() {
        scheduled = false
        guard !stopped, let buffer = pending else { return }
        pending = nil
        // Nothing open: the frame is dropped here rather than encoded into a
        // socket that is not there. An idle reconnect costs one buffer release
        // per frame interval and no encoder at all.
        guard stream != nil else { return }
        // Stamped before the pass, so the pace is measured start to start and a
        // slow encode does not quietly raise the delivered rate afterwards.
        lastSendAt = RemoteServer.monotonicNow()
        guard let session = session(for: buffer) else { return }
        session.encode(buffer, ticks: nextTicks(at: lastSendAt))
    }

    /// The 90 kHz stamp for a frame offered at `now`, forced to increase — the
    /// encoder rejects a timestamp that does not, and two frames closer together
    /// than 11 µs cannot happen under the pace ceiling anyway.
    private func nextTicks(at now: TimeInterval) -> Int64 {
        let start = origin ?? now
        origin = start
        let ticks = Int64((now - start) * Double(MPEGTSMuxer.clockHz))
        lastTicks = max(ticks, lastTicks + 1)
        return lastTicks
    }

    /// An encoder built for this raster and rate, rebuilt when either changes.
    ///
    /// A rebuild is what a signal format change or a switch into playback costs,
    /// and it is deliberately not smoothed over: the new session's first frame is
    /// a keyframe, which drags the parameter sets and the tables with it, so a
    /// receiver follows the change instead of decoding the new raster against the
    /// old SPS.
    private func session(for buffer: CVPixelBuffer) -> SRTVideoEncoder? {
        let rate = pendingFrameRate > 0
            ? Int(pendingFrameRate.rounded()) : Self.fallbackFrameRate
        let wanted = SRTVideoEncoder.Configuration(
            width: CVPixelBufferGetWidth(buffer),
            height: CVPixelBufferGetHeight(buffer),
            framesPerSecond: max(1, rate), bitsPerSecond: bitsPerSecond)
        if let encoder, encoder.configuration == wanted { return encoder }
        encoder?.invalidate()
        encoder = nil
        do {
            encoder = try SRTVideoEncoder(configuration: wanted) { [weak self] sample in
                // VideoToolbox's queue. Everything this object owns lives on its
                // own queue, so the sample comes home before it is muxed or sent.
                //
                // The weak reference is resolved ONCE, out here, and the strong
                // one is what the inner block captures. Writing `self?.queue.async
                // { self?.deliver(unit) }` captures the weak variable itself in a
                // concurrently-executing closure, which the compiler is right to
                // complain about: two threads would be reading the same optional
                // while ARC writes it.
                guard let mirror = self else { return }
                mirror.queue.async { mirror.deliver(sample) }
            }
        } catch {
            report(.refused((error as? SRTStreamError)?.message
                    ?? error.localizedDescription))
        }
        if let refused = encoder?.refusedProperties, !refused.isEmpty {
            // Not a failure: the stream still encodes, at VideoToolbox's own
            // defaults for whatever was refused. It IS the operator's bitrate
            // quietly not being honoured, so it goes where a number nobody watches
            // live belongs — the log a diagnostics bundle carries.
            os_log("SRT encoder refused %{public}s",
                   refused.joined(separator: ", "))
        }
        return encoder
    }

    // MARK: - the link

    private func deliver(_ sample: CMSampleBuffer) {
        guard !stopped, let stream,
              let unit = MPEGTSMuxer.accessUnit(from: sample) else { return }
        for datagram in muxer.datagrams(for: unit) {
            switch stream.send(datagram) {
            case .sent:
                report(.opened)
            case .dropped:
                dropped += 1
                if dropped % Self.dropLogInterval == 0 {
                    os_log("SRT dropped %d datagrams: %{public}s", dropped,
                           stream.lastSendError ?? "send buffer full")
                }
            case .noPeer:
                report(.waiting)
                return
            case .broken:
                linkLost(stream.lastSendError ?? "the SRT link closed")
                return
            }
        }
    }

    private func openLink() {
        guard !stopped, stream == nil else { return }
        do {
            let link = try factory(endpoint)
            try link.open()
            stream = link
            backoff = Self.reconnectDelay
            // A caller that returned from `open` has shaken hands; a listener has
            // only bound a port and is waiting for somebody to dial in.
            report(endpoint.role == .listener ? .waiting : .opened)
        } catch {
            let failure = error as? SRTStreamError
                ?? .configuration(error.localizedDescription)
            switch failure {
            case .link(let reason): linkLost(reason)
            case .configuration(let reason): report(.refused(reason))
            case .unavailable(let reason): report(.unavailable(reason))
            }
        }
    }

    /// The link is gone: drop it, say so once, and try again later.
    ///
    /// The encoder is dropped with it rather than kept warm. A reopened link is a
    /// new receiver as far as anything downstream knows, and a fresh session's
    /// first frame is a keyframe carrying the parameter sets — keeping the old one
    /// would send a receiver mid-GOP slices it has no SPS for.
    private func linkLost(_ reason: String) {
        stream?.close()
        stream = nil
        encoder?.invalidate()
        encoder = nil
        report(.lost(reason))
        scheduleReopen()
    }

    private func scheduleReopen() {
        guard !stopped, !reopening else { return }
        reopening = true
        let wait = backoff
        backoff = min(Self.reconnectCeiling, backoff * 2)
        queue.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self else { return }
            reopening = false
            openLink()
        }
    }

    private func report(_ event: Event) {
        guard reported != event else { return }
        reported = event
        onEvent(event)
    }
}
