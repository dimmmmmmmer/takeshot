import CSRT
import CaptureCore
import Foundation

/// What became of one datagram, from the app's side. The bridge's enum, restated
/// in Swift so nothing above this file has to import `CSRT` — which is also what
/// lets a test stand in for the whole transport.
enum SRTSendOutcome: Equatable, Sendable {
    case sent
    /// The link is up and cannot take the bytes. See `CSRTSendOutcomeDropped`.
    case dropped
    /// A listener with nobody dialled in. Normal.
    case noPeer
    /// The link is gone.
    case broken
}

/// Why a link could not be opened — and, in `isRetryable`, whether the app should
/// keep trying or hand the problem to the operator.
///
/// That distinction is the one thing this type exists for. "The receiver is not
/// running yet" and "the port is already taken" look the same at a socket and
/// need opposite responses: the first is the normal state of a venue network
/// thirty seconds before it becomes fine, and the second is a thing to go and
/// fix that a reconnect loop would hide forever.
enum SRTStreamError: Error, Equatable {
    /// No SDK headers when this was built, or no libsrt on this machine.
    ///
    /// Carries the bridge's coded answer rather than its prose, so a link that
    /// reports this reaches the status row in the same words the switch's own
    /// structural check would have used.
    case unavailable(BridgeUnavailable)
    /// Something the operator has to change.
    case configuration(String)
    /// The far end is not there.
    case link(String)

    /// The failure in one line. English for `unavailable`, which is the
    /// bridge's own diagnostic sentence — the operator-facing wording comes off
    /// `BridgeUnavailable.localizedText` at the row that shows it.
    var message: String {
        switch self {
        case .unavailable(let bridge): return bridge.english
        case .configuration(let text), .link(let text): return text
        }
    }

    var isRetryable: Bool {
        if case .link = self { return true }
        return false
    }
}

/// One SRT link, seen from the app.
///
/// A protocol for the same reason the audio input layer and the volume watch have
/// one, and for a sharper one than NDI had: the real implementation puts UDP on
/// the SET NETWORK. A suite that reached it would dial a stranger's address, or
/// bind a port on the machine running the tests, once per test. `ControllerHarness`
/// installs a fake for every controller it builds, so reaching the real one by
/// omission is not possible from a test.
///
/// `Sendable` because a stream is BUILT by the factory — which the controller
/// hands over on the MainActor — and then used on the mirror's queue. What makes
/// that safe is the confinement rather than any locking: `SRTMirror` is the
/// only thing that ever touches one, on one serial queue, and the implementations
/// say so at their declaration.
protocol SRTStreamSending: AnyObject, Sendable {
    /// Open the link. BLOCKING — a caller's connect waits for the handshake or
    /// for libsrt's connect timeout. Called only on `SRTMirror`'s queue.
    func open() throws
    /// Send one datagram. Never blocks.
    func send(_ datagram: Data) -> SRTSendOutcome
    /// Why the last send did not return `.sent`; nil when it did.
    var lastSendError: String? { get }
    /// Take the link down. Idempotent.
    func close()
}

/// The real link: a thin Swift face on `CSRTSender`, which is a stub in any build
/// without the libsrt headers (see `vendor/SRTSDK/README.md`).
///
/// `@unchecked Sendable`, and the invariant is the confinement rather than a lock:
/// `CSRTSender` owns a socket and is explicitly not thread-safe, and the ONLY
/// thing that calls into one is `SRTMirror`, on `com.takeshot.srt`, one call
/// at a time. `theWorkNeverRunsOnTheCallersQueue` is what holds that.
final class SRTStream: SRTStreamSending, @unchecked Sendable {
    private let sender: CSRTSender

    /// nil when SRT can be used; otherwise what is missing and what to install.
    /// Structural — a build with no headers, or a machine with no runtime — as
    /// against a link that could not be opened, which is an error on the call.
    ///
    /// A `BridgeUnavailable` and no longer a String: the bridge states which of
    /// its four causes this is and the app picks the words, so a Russian
    /// operator does not read a localized "Недоступно" over an English
    /// paragraph. The English is still in there and is still what a code this
    /// build does not know renders as.
    static var unavailable: BridgeUnavailable? { .srt }

    /// The loaded runtime's version, for the status row; nil in a stub build.
    static var runtimeVersion: String? { CSRTSender.runtimeVersion() }

    /// The factory shape `CaptureController.mirrors.srtStreamFactory` overrides.
    static func make(_ endpoint: SRTEndpoint) -> SRTStreamSending {
        SRTStream(endpoint)
    }

    init(_ endpoint: SRTEndpoint) {
        sender = CSRTSender(
            role: endpoint.role == .listener ? .listener : .caller,
            address: endpoint.address,
            port: UInt16(clamping: endpoint.port),
            latencyMs: Int32(clamping: endpoint.latencyMs),
            passphrase: endpoint.passphrase)
    }

    func open() throws {
        do {
            try sender.open()
        } catch {
            throw Self.classify(error)
        }
    }

    /// The bridge's `NSError` as the app's own three-way answer. The code IS the
    /// classification — see `CSRTOpenFailure`, where each case says what response
    /// it is asking for.
    ///
    /// Internal rather than private so `SRTLoopbackTests` can check the mapping
    /// against errors REAL libsrt produced, which is the only place the codes and
    /// the responses can be lined up against each other.
    static func classify(_ error: Error) -> SRTStreamError {
        let wrapped = error as NSError
        let message = wrapped.localizedDescription
        switch CSRTOpenFailure(rawValue: wrapped.code) {
        case .link: return .link(message)
        case .unavailable:
            // The error and the class methods read one `dispatch_once` runtime
            // state, so the code that goes with this sentence is the one the
            // bridge is holding right now — no second channel needed on the
            // NSError to carry it.
            return .unavailable(BridgeUnavailable(
                code: CSRTSender.unavailableCode(), english: message,
                searchPaths: CSRTSender.runtimeSearchPaths()))
        default: return .configuration(message)
        }
    }

    func send(_ datagram: Data) -> SRTSendOutcome {
        guard !datagram.isEmpty else { return .sent }
        let outcome: CSRTSendOutcome = datagram.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return .broken }
            return sender.sendDatagram(base, length: raw.count)
        }
        switch outcome {
        case .sent: return .sent
        case .dropped: return .dropped
        case .noPeer: return .noPeer
        default: return .broken
        }
    }

    var lastSendError: String? { sender.lastSendError }

    func close() {
        sender.close()
    }
}

/// What Settings shows about the SRT output. Honest by construction: there is no
/// state that means "on" without either a live link behind it or the reason there
/// is not one.
enum SRTOutputState: Equatable {
    /// The switch is off, which is the default.
    case off
    /// No picture is going anywhere yet, and nothing is wrong: a caller is
    /// shaking hands, or a listener is waiting for the receiver to dial in.
    ///
    /// ONE case for both roles rather than two, because they are the same fact
    /// about the feed and the row already knows which role it is in.
    case starting
    /// Datagrams are going out and the link is taking them.
    case sending
    /// It WAS sending and the link went. Carries what took it down.
    ///
    /// Distinct from `starting` because it is the one an operator has to see
    /// mid-shoot, and distinct from `failed` because nobody has to do anything
    /// about it — see `CaptureController+SRT` for why this one gets no toast.
    case reconnecting(String)
    /// This build (or this machine) cannot send at all: no libsrt headers when it
    /// was compiled, or no runtime installed. Carries what to install.
    ///
    /// Distinct from `failed` because it is not something flicking the switch
    /// again can change, which is why the switch is left exactly where the
    /// operator put it.
    ///
    /// The whole `BridgeUnavailable` and not its text, so the row renders in
    /// whatever language the app is in WHEN IT DRAWS. An operator who throws
    /// this switch and then changes the language would otherwise be reading a
    /// paragraph in the language they just left.
    case unavailable(BridgeUnavailable)
    /// Something the operator has to change: an address that resolves to
    /// nothing, a port already bound, a passphrase SRT will not take. Carries the
    /// reason, and the switch stays ON so the field to fix it stays on screen.
    case failed(String)
}
