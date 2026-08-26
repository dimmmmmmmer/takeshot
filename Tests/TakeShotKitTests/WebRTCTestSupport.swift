import Foundation
import Testing

@testable import TakeShotKit

/// A peer connection that never touches a network.
///
/// The real one generates a DTLS certificate and gathers ICE candidates off
/// every interface the machine has — so this is the only kind of peer a test
/// may have, and unlike a belt-and-braces fake it is load bearing twice:
/// `ControllerHarness` installs one for every controller it builds, and it is
/// what makes the signalling route testable at all on a build with no
/// libdatachannel headers in it, which is CI and every machine that has not
/// dropped them in.
///
/// Lock-guarded rather than main-actor-confined, like `FakeSRTStream`: it is
/// called on the viewer's queue and read from the test.
final class FakeWebRTCPeer: WebRTCPeering, @unchecked Sendable {
    private let lock = NSLock()
    private var storedPackets: [Data] = []
    private var storedQueues: [String] = []
    private var storedOffers: [String] = []
    private var storedClosed = false
    private var storedKeyframeRequests = 0
    private var stateHandler: (@Sendable (WebRTCPeerState) -> Void)?
    private var keyframeHandler: (@Sendable () -> Void)?
    private var failure: WebRTCError?

    let plan: WebRTCOffer.VideoPlan
    let ssrc: UInt32

    init(plan: WebRTCOffer.VideoPlan, ssrc: UInt32,
         failure: WebRTCError? = nil) {
        self.plan = plan
        self.ssrc = ssrc
        self.failure = failure
    }

    /// The RTP that reached the wire.
    var packets: [Data] { lock.withLock { storedPackets } }
    /// The label of the queue each send ran on. What proves the packetizing is
    /// not on the capture queue — or on the shared encoder's, where one phone's
    /// socket would pace every other consumer.
    var queues: [String] { lock.withLock { storedQueues } }
    var offers: [String] { lock.withLock { storedOffers } }
    var isClosed: Bool { lock.withLock { storedClosed } }

    /// The answer this fake hands back. Recognisable, and shaped enough like an
    /// answer that a test asserting on the body is asserting on something.
    var answerSDP: String {
        "v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n"
            + "m=video 9 UDP/TLS/RTP/SAVPF \(plan.payloadType)\r\n"
            + "a=mid:\(plan.mid)\r\na=sendonly\r\n"
            + "a=ssrc:\(ssrc) cname:takeshot\r\n"
    }

    func answer(offer: String) throws -> String {
        try lock.withLock {
            storedOffers.append(offer)
            if let failure { throw failure }
        }
        return answerSDP
    }

    func send(rtp: Data) -> Bool {
        let label = String(cString: __dispatch_queue_get_label(nil))
        lock.withLock {
            storedQueues.append(label)
            storedPackets.append(rtp)
        }
        return true
    }

    func observe(state: @escaping @Sendable (WebRTCPeerState) -> Void,
                 keyframe: @escaping @Sendable () -> Void) {
        lock.withLock {
            stateHandler = state
            keyframeHandler = keyframe
        }
    }

    func close() {
        lock.withLock { storedClosed = true }
    }

    /// Drive the state callback, the way libdatachannel's thread would.
    func report(_ state: WebRTCPeerState) {
        lock.withLock { stateHandler }?(state)
    }

    /// And the PLI handler, the way a browser that lost a picture would.
    func requestKeyframe() {
        lock.withLock { keyframeHandler }?()
    }
}

/// Every peer a controller built, in order. Lock-guarded: the factory runs
/// wherever the offer landed while the test reads it.
final class WebRTCPeerLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [FakeWebRTCPeer] = []
    private let failure: WebRTCError?

    init(failure: WebRTCError? = nil) {
        self.failure = failure
    }

    func build(_ plan: WebRTCOffer.VideoPlan, _ ssrc: UInt32) -> FakeWebRTCPeer {
        let peer = FakeWebRTCPeer(plan: plan, ssrc: ssrc, failure: failure)
        lock.withLock { stored.append(peer) }
        return peer
    }

    var all: [FakeWebRTCPeer] { lock.withLock { stored } }
    var latest: FakeWebRTCPeer? { all.last }
}

/// Posting an offer at the signalling route, and what came back.
@MainActor
enum WebRTCHarness {
    struct Reply {
        var status: Int
        var contentType: String
        var body: String
    }

    /// One POST at `/webrtc-offer`, with whatever body the caller wants —
    /// including one that is not JSON at all, which is half of what this route
    /// has to survive.
    static func post(port: Int, body: Data) async throws -> Reply {
        let url: URL = try #require(
            URL(string: "http://127.0.0.1:\(port)\(RemoteWebRTC.offerPath)"))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await RemoteHarness.session().data(for: request)
        let http: HTTPURLResponse = try #require(response as? HTTPURLResponse)
        return Reply(
            status: http.statusCode,
            contentType: http.value(forHTTPHeaderField: "Content-Type") ?? "",
            body: String(bytes: data, encoding: .utf8) ?? "")
    }

    /// The ordinary case: a well-formed offer with a PIN on it.
    static func offer(port: Int, pin: String,
                      sdp: String = WebRTCOfferFixture.chromeRecvOnlyVideo)
        async throws -> Reply {
        let object: [String: Any] = [RemoteWebRTC.pinField: pin,
                                     RemoteWebRTC.sdpField: sdp]
        return try await post(
            port: port,
            body: try JSONSerialization.data(withJSONObject: object))
    }
}
