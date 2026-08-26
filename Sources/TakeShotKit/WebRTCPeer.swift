import CDataChannel
import Foundation

/// Where one browser's connection has got to. The bridge's enum, restated in
/// Swift so nothing above this file has to import `CDataChannel` — which is
/// also what lets a test stand in for the whole transport.
enum WebRTCPeerState: Equatable, Sendable {
    case new
    case connecting
    /// ICE and DTLS are up: RTP sent from here reaches the browser.
    case connected
    /// The path went away and may come back on its own. NOT a teardown — a
    /// phone that went behind a truck is the normal case on a set.
    case disconnected
    /// ICE gave up, or the browser closed the page. This connection is over and
    /// the next picture needs a fresh offer.
    case failed
    case closed

    /// Whether this connection can still become a picture. The one question the
    /// app asks of a state, so it is answered here rather than at each caller.
    var isOver: Bool { self == .failed || self == .closed }
}

/// Why an offer could not be answered — and, in the case names, what the
/// signalling route should say back.
///
/// The distinction is the whole reason this is not one error: "this build has
/// no WebRTC" is a fact about the app that a page should report and stop
/// retrying; "that is not an offer I can answer" is a fact about the request;
/// and a library that refused a step it normally takes is worth showing
/// verbatim because it is rare enough that what it said is the diagnosis.
enum WebRTCError: Error, Equatable {
    case unavailable(String)
    case offer(String)
    case runtime(String)

    var message: String {
        switch self {
        case .unavailable(let text), .offer(let text), .runtime(let text):
            return text
        }
    }
}

/// One WebRTC peer connection, seen from the app.
///
/// A protocol for the same reason `SRTStreamSending` is one, and for a sharper
/// reason than SRT had: the real implementation puts UDP on the set network AND
/// generates a DTLS certificate, and a suite that reached it would do both once
/// per test on whatever machine is running them. `ControllerHarness` installs a
/// fake for every controller it builds, so reaching the real one by omission is
/// not possible from a test.
///
/// `Sendable` because a peer is BUILT on the MainActor and then used on the
/// viewer's queue. What makes that safe is the confinement rather than any
/// locking: `WebRTCViewer` is the only thing that ever touches one.
protocol WebRTCPeering: AnyObject, Sendable {
    /// Take the browser's offer and hand back the answer SDP.
    ///
    /// BLOCKING — it waits for ICE gathering, so the answer carries every
    /// candidate and one HTTP exchange is the whole of signalling. Never on
    /// main, never on the remote server's queue.
    func answer(offer: String) throws -> String
    /// Send one complete RTP packet. Never blocks. False while the track is not
    /// open, which is every moment before the browser has finished connecting.
    func send(rtp: Data) -> Bool
    /// The two things the far end tells us: where the connection has got to,
    /// and that it has lost enough of the picture to need a keyframe.
    /// Both are called on the library's own threads.
    func observe(state: @escaping @Sendable (WebRTCPeerState) -> Void,
                 keyframe: @escaping @Sendable () -> Void)
    /// Take the connection down. Idempotent.
    func close()
}

/// The real peer: a thin Swift face on `CDCPeerConnection`, which is a stub in
/// any build without the libdatachannel headers (see
/// `vendor/libdatachannel/README.md`).
///
/// `@unchecked Sendable`, and the invariant is the confinement rather than a
/// lock: the bridge owns a peer connection and the ONLY thing that calls into
/// one is `WebRTCViewer`.
final class WebRTCPeer: WebRTCPeering, @unchecked Sendable {
    /// How long the answer waits for ICE gathering.
    ///
    /// Generous for what it covers and short for what it costs: with no STUN
    /// and no TURN in the path, gathering is an enumeration of this machine's
    /// interfaces and finishes in milliseconds. Three seconds is there for the
    /// machine where that enumeration hangs, and the page gets an error rather
    /// than a fetch that never returns.
    static let gatheringTimeout: TimeInterval = 3

    /// The canonical name the browser sees on the stream. One value for the
    /// app rather than one per viewer: it names the SOURCE, and there is one.
    static let cname = "takeshot"

    private let connection: CDCPeerConnection

    /// nil when WebRTC can be used; otherwise what is missing and what to do
    /// about it, in English like the other bridge errors. Structural — a build
    /// with no headers, or a machine with no runtime — as against an offer that
    /// could not be answered, which is an error on the call.
    static var unavailableReason: String? { CDCPeerConnection.unavailableReason() }

    /// The factory shape `CaptureController.mirrors.webrtcPeerFactory`
    /// overrides.
    static func make(_ plan: WebRTCOffer.VideoPlan, ssrc: UInt32) -> WebRTCPeering {
        WebRTCPeer(plan, ssrc: ssrc)
    }

    init(_ plan: WebRTCOffer.VideoPlan, ssrc: UInt32) {
        connection = CDCPeerConnection(
            mid: plan.mid, payloadType: plan.payloadType,
            formatParameters: plan.formatParameters, ssrc: ssrc,
            cname: Self.cname)
    }

    func answer(offer: String) throws -> String {
        do {
            return try connection.answerOffer(
                offer, gatheringTimeout: Self.gatheringTimeout)
        } catch {
            // The bridge's code IS the classification; see `classify`.
            throw Self.classify(error as NSError)
        }
    }

    /// The bridge's `NSError` as the app's own three-way answer. The code IS the
    /// classification — see `CDCAnswerFailure`, where each case says what
    /// response it is asking for.
    static func classify(_ error: NSError?) -> WebRTCError {
        let message = error?.localizedDescription ?? "WebRTC refused the offer"
        switch CDCAnswerFailure(rawValue: error?.code ?? 0) {
        case .unavailable: return .unavailable(message)
        case .offer: return .offer(message)
        default: return .runtime(message)
        }
    }

    func send(rtp: Data) -> Bool {
        guard !rtp.isEmpty else { return true }
        return rtp.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return false }
            return connection.sendRTP(base, length: raw.count)
        }
    }

    func observe(state: @escaping @Sendable (WebRTCPeerState) -> Void,
                 keyframe: @escaping @Sendable () -> Void) {
        connection.onStateChange = { raw in state(Self.state(raw)) }
        connection.onKeyframeRequest = keyframe
    }

    static func state(_ raw: CDCPeerState) -> WebRTCPeerState {
        switch raw {
        case .new: return .new
        case .connecting: return .connecting
        case .connected: return .connected
        case .disconnected: return .disconnected
        case .failed: return .failed
        case .closed: return .closed
        @unknown default: return .failed
        }
    }

    func close() {
        connection.close()
    }
}
