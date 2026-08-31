import CaptureCore
import CoreMedia
@preconcurrency import CoreVideo
import Foundation
import os.log

/// Mirrors the viewer to an SRT endpoint — picture and sound — on a queue of
/// its own.
///
/// **Neither encode is here, and that is the point of the split.** One H.264
/// session serves every live consumer (`LiveVideoEncoder`) and one AAC session
/// serves everything taking sound (`LiveAudioEncoder`); this file registers a
/// sink on each, and what arrives is an encoded unit somebody else paid for. A
/// second `VTCompressionSession` for the second thing watching the same picture
/// is the cost this app cannot pay, on a machine whose actual job is writing
/// ProRes to a card. What is left here is the SRT half and nothing else: the
/// transport stream, the socket, and the reconnect.
///
/// **Two elementary streams, one link, one clock.** The picture is on PID 0x0100
/// and the sound on 0x0101, both stamped against the shared `LiveClock` on the
/// transport stream's own 90 kHz, and the program map declares the second one
/// only once sound has actually arrived (see `deliver(audio:)`). The sound is
/// taken off `CapturePipeline.addAudioTap` — the mix the cart's speakers get,
/// without the switch the cart's speakers are behind.
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
final class SRTMirror: @unchecked Sendable {
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
        /// This build or this machine cannot send at all. Carries the bridge's
        /// coded answer, so the status row picks its own words for it.
        case unavailable(BridgeUnavailable)
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

    /// How often the link is asked for its round trip, in frames sent.
    ///
    /// Counted in frames rather than on a timer because a timer would keep
    /// asking a link that has nothing going out, and the measurement is only
    /// meaningful while datagrams are flowing. 150 is about six seconds at 25
    /// fps — slow enough that the statistics call costs nothing, often enough
    /// that a network which got worse when the crew moved outside is noticed
    /// within a setup rather than within a take.
    static let roundTripProbeFrames = 150

    /// The shortest gap between two retunes.
    ///
    /// Re-opening costs the far end a gap of about a second, so it is worth
    /// paying only for a link that is genuinely too tight — never on a wobble.
    /// Thirty seconds on top of `SRTLatency`'s 20 % band means a link whose RTT
    /// is drifting settles instead of oscillating.
    static let retuneInterval: TimeInterval = 30

    private let queue = DispatchQueue(label: SRTMirror.queueLabel,
                                      qos: .userInitiated)
    private let endpoint: SRTEndpoint
    /// The shared session. Held strongly: this object is one of its consumers
    /// and must not outlive the samples it is registered for.
    private let encoder: LiveVideoEncoder
    /// The shared AAC encode, on the same terms — nil in a build or a test that
    /// has no codec for it, and the picture goes out alone.
    private let audioEncoder: LiveAudioEncoder?
    private let factory: @Sendable (SRTEndpoint) throws -> SRTStreamSending
    private let onEvent: @Sendable (Event) -> Void
    /// The buffer the link is running with and the round trip it reported, for
    /// the settings row. Separate from `Event` on purpose: the events are a
    /// state machine that dedupes itself, and a measurement that changes by a
    /// millisecond is not a state change.
    private let onMeasurement: @Sendable (Int, Double?) -> Void

    // MARK: - queue-confined state

    private var stream: SRTStreamSending?
    private var muxer = MPEGTSMuxer()
    private var stopped = false
    private var backoff = SRTMirror.reconnectDelay
    private var reopening = false
    private var dropped = 0
    /// Frames since the link was last asked for its round trip.
    private var sinceProbe = 0
    /// The last round trip the link reported; nil until one arrives.
    private var roundTrip: Double?
    /// The delivery buffer the OPEN link was given, which is not necessarily
    /// the endpoint's: a retuned link is running on a measured figure.
    private var openLatencyMs: Int
    /// When the link was last re-opened to change its buffer.
    private var lastRetune: DispatchTime?
    /// The last event handed upwards. A repeat is swallowed: each one is a
    /// MainActor hop and a `@Published` write, and "still reconnecting" arriving
    /// once a second would re-render the settings window for no news.
    private var reported: Event?

    init(endpoint: SRTEndpoint, encoder: LiveVideoEncoder,
         audioEncoder: LiveAudioEncoder? = nil,
         factory: @escaping @Sendable (SRTEndpoint) throws -> SRTStreamSending,
         onEvent: @escaping @Sendable (Event) -> Void,
         onMeasurement: @escaping @Sendable (Int, Double?) -> Void
             = { _, _ in }) {
        self.endpoint = endpoint
        self.openLatencyMs = endpoint.latencyMs
        self.encoder = encoder
        self.audioEncoder = audioEncoder
        self.factory = factory
        self.onEvent = onEvent
        self.onMeasurement = onMeasurement
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
        audioEncoder?.removeSink(self)
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
        guard !stopped, stream != nil,
              let unit = MPEGTSMuxer.accessUnit(from: sample) else { return }
        send(muxer.datagrams(for: unit))
        sinceProbe += 1
        if sinceProbe >= Self.roundTripProbeFrames {
            sinceProbe = 0
            probeRoundTrip()
        }
    }

    /// One encoded access unit of SOUND as datagrams on the same socket.
    ///
    /// **The program map is turned on by the first unit that actually arrives,
    /// not by the encoder existing.** A PMT that declares an audio PID nothing
    /// ever feeds is a receiver waiting for sound that is not coming — the same
    /// trap `TakeWriter+Audio` pads a starved track to avoid, one transport
    /// along — and "an AAC encoder was constructed" is not the same claim as
    /// "this machine can encode AAC". So the map follows the bytes, and the
    /// keyframe asked for here is what carries the new map to whoever is
    /// already watching; without it a receiver would wait out the rest of the
    /// GOP with audio packets it has been told nothing about.
    private func deliver(audio unit: LiveAudioEncoder.AccessUnit) {
        guard !stopped, stream != nil else { return }
        if !muxer.carriesAudio {
            muxer.carriesAudio = true
            encoder.requestKeyframe()
        }
        send(muxer.datagrams(forAudio: unit))
    }

    /// Datagrams onto the socket, and what each outcome means for the link.
    /// Shared by the two elementary streams: they are the same socket and the
    /// same link, and a second copy of this is a second place for a `.broken`
    /// to be read as a drop.
    private func send(_ datagrams: [Data]) {
        guard let stream else { return }
        for datagram in datagrams {
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
            var opening = endpoint
            opening.latencyMs = wantedLatencyMs
            openLatencyMs = opening.latencyMs
            onMeasurement(openLatencyMs, roundTrip)
            let link = try factory(opening)
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

    /// **The delivery buffer this link should open with, which is a
    /// measurement and not a preference** (owner: "пусть это не на
    /// пользователе будет а автоматом считается").
    ///
    /// SRT recovers a lost packet by asking for it again, so the buffer has to
    /// hold the picture for several round trips — a number an operator on set
    /// cannot be expected to know about a network they did not build, and which
    /// the link itself reports. `SRTLatency` turns one into the other; until a
    /// measurement arrives it is the floor, which is what the field defaulted
    /// to anyway.
    ///
    /// An endpoint carrying an EXPLICIT figure keeps it. That is not an
    /// operator's guess: it comes from a pasted `srt://…?latency=` URL, which
    /// is the receiving end stating what it wants, and both ends of an SRT link
    /// have to agree.
    private var wantedLatencyMs: Int {
        endpoint.latencyIsExplicit
            ? endpoint.latencyMs
            : SRTLatency.recommended(forRTT: roundTrip)
    }

    /// Ask the link how far away the far end is, and re-open it if the buffer
    /// it is running with is too small for the answer.
    ///
    /// **A link whose buffer is too tight does not fail — it breaks up.** It
    /// keeps its socket, keeps sending, and loses the packets it did not have
    /// room to ask for again, indefinitely. So there is no reconnect to ride
    /// along on: the only way a measured figure ever reaches the wire is to
    /// take the link down on purpose. That costs the far end about a second,
    /// which is why it is bounded on all three sides — only upwards, only
    /// outside `SRTLatency`'s 20 % band, and never twice inside
    /// `retuneInterval`.
    ///
    /// The recorder is not in this path and is not consulted: the SRT feed is a
    /// monitoring picture, not the deliverable, and a second of black on it is
    /// cheaper than a take's worth of a picture that is breaking up.
    private func probeRoundTrip() {
        guard let measured = stream?.roundTripMs else { return }
        roundTrip = measured
        onMeasurement(openLatencyMs, measured)
        guard !endpoint.latencyIsExplicit,
              SRTLatency.wantsReconnect(current: openLatencyMs, forRTT: measured)
        else { return }
        let now = DispatchTime.now()
        if let lastRetune,
           now.uptimeNanoseconds - lastRetune.uptimeNanoseconds
               < UInt64(Self.retuneInterval * 1_000_000_000) { return }
        lastRetune = now
        os_log("SRT retuning the delivery buffer: %d ms → %d ms at %.1f ms RTT",
               openLatencyMs, SRTLatency.recommended(forRTT: measured), measured)
        // Through the loss path so the sinks come off and the reconnect keeps
        // its backoff — the difference is that this one is deliberate, and the
        // buffer it comes back with is the measured one.
        linkLost(L("srt_retuned"))
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
        // The same hop for the sound, off the AAC encoder's queue rather than
        // VideoToolbox's. Nothing about the two streams is ordered against each
        // other here and nothing needs to be: a receiver puts them back
        // together from the stamps, which is what one 90 kHz clock is for.
        audioEncoder?.addSink(self) { [weak self] unit in
            guard let mirror = self else { return }
            mirror.queue.async { mirror.deliver(audio: unit) }
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
        audioEncoder?.removeSink(self)
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
