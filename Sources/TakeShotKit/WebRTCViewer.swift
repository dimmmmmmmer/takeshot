import CoreMedia
import Foundation
import os.log

/// One browser watching the viewer over WebRTC: its peer connection, its RTP
/// packetizer, and the queue both live on.
///
/// **The SRT mirror's shape, one wire format along.** Frames are not seen here
/// at all — `LiveVideoEncoder` compresses the picture once for everybody, this
/// registers a sink on it, and what arrives is a `CMSampleBuffer` somebody else
/// paid for. From there the path is the same two steps the transport stream
/// takes: `MPEGTSMuxer.accessUnit(from:)` turns the sample into Annex B bytes
/// with a 90 kHz stamp, and a packetizer turns that into datagrams. Only the
/// packetizer differs.
///
/// **One viewer is one page load.** WebRTC has no reconnect: an offer and an
/// answer set up one connection, and a browser that lost it makes another. So
/// there is no backoff here and nothing to reopen — a connection that fails is
/// dropped, and the page offers again. That is the opposite of the SRT mirror
/// and it is right for the opposite reason: an SRT receiver is a fixed address
/// that comes and goes, and a browser is a page that reloads.
///
/// **Nothing here can block the frame path.** The encoder's thread hands a
/// sample over and returns; everything after that is on this object's own
/// queue; and `send` is asynchronous inside libdatachannel, so a phone that
/// cannot take the bytes drops them rather than parking anything.
final class WebRTCViewer: @unchecked Sendable {
    /// What the controller is told. Two states, because there are only two
    /// things it does about one: a picture is going, or this viewer is over and
    /// its slot can be given back.
    enum Event: Equatable, Sendable {
        case connected
        case gone
    }

    /// The queue the packetizing and the sending run on. Named so a test can
    /// assert that neither happens on the capture queue — or on the encoder's,
    /// which would put every other consumer behind this phone's socket.
    static let queueLabel = "com.takeshot.webrtc"

    /// Viewers one app will carry at once.
    ///
    /// The same reasoning as `RemoteServer.maximumClients` and a smaller
    /// number: a phone watching video costs an encode nobody else pays for
    /// (none — the session is shared) plus a packetize and a send per frame,
    /// which is cheap, and a DTLS handshake and an ICE agent, which are not.
    /// Four is a director, a focus puller, a script supervisor and one spare,
    /// on a machine that is recording.
    static let maximumViewers = 4

    /// How long a viewer may hold a slot without connecting.
    ///
    /// **The cap above is only a defence if slots come back**, and a WebRTC
    /// connection that never completes does not announce itself: ICE keeps
    /// checking, and libdatachannel does not call it failed until its own
    /// consent timeout — half a minute or more. A page that offers, fails for
    /// some local reason and offers again on its own backoff can therefore take
    /// every slot on the Mac before the first one gives up, and the feature is
    /// then closed to the whole crew until somebody restarts the app.
    ///
    /// Twenty seconds is generous against what a real page does: gathering is
    /// finished on both sides before the POST, so all that is left is a
    /// connectivity check and a DTLS handshake on one network segment —
    /// hundreds of milliseconds. It is the same reasoning, and nearly the same
    /// number, as `RemoteClient.handshakeDeadline`.
    static let connectDeadline: TimeInterval = 20

    private let queue = DispatchQueue(label: WebRTCViewer.queueLabel,
                                      qos: .userInitiated)
    private let peer: WebRTCPeering
    private let encoder: LiveVideoEncoder
    private let onEvent: @Sendable (Event) -> Void

    // MARK: - queue-confined state

    private var packetizer: RTPH264Packetizer
    private var stopped = false
    private var subscribed = false
    /// Nothing goes out until a keyframe does.
    ///
    /// **This is the rule that makes "ask for a keyframe on join" reliable
    /// rather than a race.** The ask is answered by the next frame the encoder
    /// compresses, and between registering and that frame there may already be
    /// a sample in flight from before — a mid-GOP slice with no parameter sets
    /// in front of it. Sending it is bytes the browser cannot decode, which it
    /// answers with a PLI, which asks for the keyframe that was already coming.
    /// So the viewer simply waits, and its first packet is always the start of
    /// a picture.
    private var awaitingKeyframe = true
    /// Packets the transport refused, logged rather than shown — see
    /// `SRTVideoMirror.dropLogInterval` for why a number nobody watches live
    /// belongs in the log a diagnostics bundle carries.
    private var dropped = 0

    init(peer: WebRTCPeering, plan: WebRTCOffer.VideoPlan, ssrc: UInt32,
         encoder: LiveVideoEncoder,
         connectDeadline: TimeInterval = WebRTCViewer.connectDeadline,
         onEvent: @escaping @Sendable (Event) -> Void) {
        self.peer = peer
        self.encoder = encoder
        self.onEvent = onEvent
        // The first sequence number is random, as RFC 3550 asks: a receiver
        // that starts at a known number is a receiver whose stream can be
        // spoofed by anything that can guess it, and there is no cost to not
        // being guessable.
        packetizer = RTPH264Packetizer(
            ssrc: ssrc, payloadType: plan.payloadType,
            firstSequenceNumber: UInt16.random(in: 0...UInt16.max))
        peer.observe(state: { [weak self] state in
            // libdatachannel's thread. Everything this object owns lives on its
            // own queue, so the news hops before it touches any of it.
            self?.apply(state)
        }, keyframe: { [weak self] in
            // The browser has lost enough of the picture to be unable to carry
            // on. What it is asking for is exactly the dial
            // `SRTVideoEncoder.requestKeyframe` added, and asking the SHARED
            // encoder is right: one keyframe answers every viewer that lost the
            // same packet, which on one Wi-Fi network is usually all of them.
            self?.encoder.requestKeyframe()
        })
        // The slot's own deadline. Armed here rather than after the answer, so
        // a connection that dies during signalling is covered by the same
        // clock as one that dies during ICE.
        queue.asyncAfter(deadline: .now() + connectDeadline) { [weak self] in
            self?.giveUpIfNotConnected()
        }
    }

    /// The deadline fired: a viewer that has not started sending is one whose
    /// slot belongs to somebody who can. Idempotent with every other way this
    /// object ends — the controller's registry answers a second removal with
    /// nothing.
    private func giveUpIfNotConnected() {
        guard !stopped, !subscribed else { return }
        onEvent(.gone)
    }

    /// Answer the browser's offer. BLOCKING — it waits for ICE gathering; the
    /// caller owes it a queue that may park (see `CaptureController+WebRTC`).
    func answer(offer: String) throws -> String {
        try peer.answer(offer: offer)
    }

    /// Take this viewer down. Idempotent; the sink goes first and
    /// synchronously, so a viewer the controller has just dropped stops costing
    /// the encoder a fan-out before the queue hop below is even scheduled.
    func stop() {
        encoder.removeSink(self)
        peer.close()
        queue.async { [self] in
            stopped = true
            subscribed = false
        }
    }

    // MARK: - the connection

    private func apply(_ state: WebRTCPeerState) {
        queue.async { [self] in
            guard !stopped else { return }
            if state == .connected {
                subscribe()
                onEvent(.connected)
            } else if state.isOver {
                encoder.removeSink(self)
                subscribed = false
                onEvent(.gone)
            }
        }
    }

    /// Start taking samples, and ask for a keyframe with the first one.
    ///
    /// **This is what `requestKeyframe()` was added for.** A viewer that joins
    /// mid-GOP is handed slices it has no SPS for and shows nothing at all
    /// until the next scheduled keyframe — up to a second of black on a page
    /// somebody just opened. Asking collapses with every other ask in flight,
    /// so a crew opening the page at once costs one keyframe between them.
    private func subscribe() {
        guard !subscribed else { return }
        subscribed = true
        // The weak reference is resolved ONCE, out here — see the same note in
        // `SRTVideoMirror.subscribe` for why the inner block must capture a
        // strong one.
        encoder.addSink(self) { [weak self] sample in
            guard let viewer = self else { return }
            viewer.queue.async { viewer.deliver(sample) }
        }
        encoder.requestKeyframe()
    }

    /// One encoded sample as RTP packets on the wire.
    ///
    /// The access unit comes from the same call the transport stream starts
    /// from, and nothing about the picture is decided here: a keyframe already
    /// carries its parameter sets in those bytes, which is what makes a browser
    /// joining mid-stream able to decode at all.
    private func deliver(_ sample: CMSampleBuffer) {
        guard !stopped, let unit = MPEGTSMuxer.accessUnit(from: sample)
        else { return }
        // See `awaitingKeyframe`. The gate closes once and never again: a
        // reconnect is a new page and a new viewer, and a NACK is the
        // transport's problem rather than this one's.
        if awaitingKeyframe {
            guard unit.isKeyframe else { return }
            awaitingKeyframe = false
        }
        for packet in packetizer.packets(for: unit) where !peer.send(rtp: packet) {
            dropped += 1
            if dropped % SRTVideoMirror.dropLogInterval == 0 {
                os_log("WebRTC dropped %d packets", dropped)
            }
        }
    }
}
