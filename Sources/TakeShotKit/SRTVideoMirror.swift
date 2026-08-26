import CaptureCore
import CoreMedia
@preconcurrency import CoreVideo
import Foundation
import os.log

/// Mirrors the viewer to an SRT endpoint, on a queue of its own.
///
/// **The encode is not here any more, and that is the point of the split.** One
/// H.264 session serves every live consumer (`LiveVideoEncoder`) — this file
/// registers a sink on it, and what arrives is an encoded sample somebody else
/// paid for. A second `VTCompressionSession` for the second thing watching the
/// same picture is the cost this app cannot pay, on a machine whose actual job
/// is writing ProRes to a card. What is left here is the SRT half and nothing
/// else: the transport stream, the socket, and the reconnect.
///
/// The discipline is `MultiviewEncoder`'s and `PlayoutFeeder`'s: the mux and the
/// send run on THIS queue — never on capture, never on main — and the sample
/// arrives on VideoToolbox's thread and hops here before anything touches it.
///
/// **Nothing in this path can block the frame path, by construction rather than
/// by being fast.** The encoder's queue hands a sample over and returns. The
/// socket is opened with sending asynchronous, so a link that cannot take the
/// bytes says "again" and the datagram is dropped. And a connect — the one call
/// here that really can park for seconds — happens on this queue, where parking
/// costs this feed's frames and nothing else: the encoder's queue is not
/// behind it, so a WebRTC viewer keeps its picture through an SRT reconnect.
///
/// **A dead link is the normal case, so it is a state and not an error.** On a
/// venue network the receiver is closed half the day, the Wi-Fi drops, somebody
/// re-patches a switch. The link is reopened with a backoff, the operator is
/// told once, and nothing here can reach the recorder: the whole file calls an
/// encoder's samples and a socket, and neither the pipeline nor the writer
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

    /// The queue everything here runs on. Named so a test can assert that the
    /// socket is never touched from the capture queue — or from the encoder's.
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

    private let queue = DispatchQueue(label: SRTVideoMirror.queueLabel,
                                      qos: .userInitiated)
    private let endpoint: SRTEndpoint
    /// The shared session. Held strongly: this object is one of its consumers
    /// and must not outlive the samples it is registered for.
    private let encoder: LiveVideoEncoder
    private let factory: @Sendable (SRTEndpoint) throws -> SRTStreamSending
    private let onEvent: @Sendable (Event) -> Void

    // MARK: - queue-confined state

    private var stream: SRTStreamSending?
    private var muxer = MPEGTSMuxer()
    private var stopped = false
    private var backoff = SRTVideoMirror.reconnectDelay
    private var reopening = false
    private var dropped = 0
    /// The last event handed upwards. A repeat is swallowed: each one is a
    /// MainActor hop and a `@Published` write, and "still reconnecting" arriving
    /// once a second would re-render the settings window for no news.
    private var reported: Event?

    init(endpoint: SRTEndpoint, encoder: LiveVideoEncoder,
         factory: @escaping @Sendable (SRTEndpoint) throws -> SRTStreamSending,
         onEvent: @escaping @Sendable (Event) -> Void) {
        self.endpoint = endpoint
        self.encoder = encoder
        self.factory = factory
        self.onEvent = onEvent
    }

    /// Open the link. Asynchronous on purpose: a caller's connect blocks, and the
    /// MainActor must not be the thread it blocks.
    func start() {
        queue.async { [self] in openLink() }
    }

    /// Take the link down. Asynchronous on purpose: a send or a connect may be in
    /// flight and the main actor must not park behind it. The serial queue orders
    /// this after that call and before anything delivered later, and `stopped`
    /// makes every one of those inert.
    ///
    /// The sink goes FIRST and synchronously: a mirror the operator has just
    /// switched off must stop costing the encoder a fan-out before the queue hop
    /// below has even been scheduled.
    func stop() {
        encoder.removeSink(self)
        queue.async { [self] in
            stopped = true
            stream?.close()
            stream = nil
        }
    }

    // MARK: - the link

    /// One encoded sample as transport-stream datagrams on the socket.
    ///
    /// The access unit comes from `MPEGTSMuxer.accessUnit(from:)`, which is the
    /// one seam a `CMSampleBuffer` becomes bytes at — the WebRTC viewer starts
    /// from exactly the same call and puts the same access unit in RTP instead.
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
            subscribe()
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

    /// Start taking samples, and ask for a keyframe with the first one.
    ///
    /// A reopened link is a NEW receiver as far as anything downstream knows,
    /// and it needs the parameter sets before it needs a slice — otherwise it is
    /// handed mid-GOP bytes it has no SPS for. The old code got that by throwing
    /// the encoder away and building another, which is not available to a
    /// session somebody else is also watching; `requestKeyframe` is what
    /// replaced it, and it is cheaper than the rebuild ever was.
    private func subscribe() {
        // The weak reference is resolved ONCE, out here, and the strong one is
        // what the inner block captures. Writing `self?.queue.async {
        // self?.deliver(unit) }` captures the weak variable itself in a
        // concurrently-executing closure, which the compiler is right to
        // complain about: two threads would be reading the same optional while
        // ARC writes it.
        encoder.addSink(self) { [weak self] sample in
            guard let mirror = self else { return }
            mirror.queue.async { mirror.deliver(sample) }
        }
        encoder.requestKeyframe()
    }

    /// The link is gone: drop it, say so once, and try again later.
    ///
    /// The sink goes with it. That is what keeps the old promise — an idle
    /// reconnect costs no encode at all — now that the session is shared: with
    /// no SRT sink and no viewer, the encoder has nothing to fan out to and
    /// drops the frame before compressing it.
    private func linkLost(_ reason: String) {
        encoder.removeSink(self)
        stream?.close()
        stream = nil
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
