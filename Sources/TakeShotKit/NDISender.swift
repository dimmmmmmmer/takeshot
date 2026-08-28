import CNDI
@preconcurrency import CoreVideo
import Foundation

/// A frame rate as NDI states it: a rational, not a rounded decimal.
///
/// **The one piece of the old design that had to come back with the feature.**
/// It was dropped when SRT replaced NDI, and the reason it was dropped is the
/// reason it is here again: MPEG-TS has no frame-rate field — it timestamps on
/// a 90 kHz clock, so the rate is something a receiver counts. NDI DECLARES the
/// rate on every frame, so a receiver handed 23.976/1 has to guess at the
/// pull-down, and the guess is what shows up as a stutter on a director's
/// monitor. 23.976 is 24000/1001 exactly and nothing else.
///
/// Being a value type is also the only way this is testable on a machine with
/// no NDI headers: the conversion needs no sender, no SDK and no network.
struct NDIFrameRate: Equatable, Sendable {
    let numerator: Int32
    let denominator: Int32

    /// The rate to state when nothing has told us one yet. 1080p25 is the
    /// raster the playout mirror falls back to for the same reason.
    static let fallback = NDIFrameRate(numerator: 25, denominator: 1)

    private init(numerator: Int32, denominator: Int32) {
        self.numerator = numerator
        self.denominator = denominator
    }

    /// How far a rate may sit from the exact N/1001 value and still be taken as
    /// that rate. A board reports 23.976023976…, a sidecar or a UI may have
    /// rounded it to 23.98, and both mean 24000/1001; 0.01 catches the rounded
    /// forms while staying an order of magnitude clear of the nearest integer
    /// rate (25 is 0.025 from 25000/1001, the tightest of them).
    private static let fractionalTolerance = 0.01

    init(fps: Double) {
        guard fps.isFinite, fps > 0, fps < 1000 else {
            self = .fallback
            return
        }
        // The 1000/1001 family first: 23.976, 29.97, 59.94 are the rates a set
        // actually runs at, and every one of them is an integer rate pulled
        // down. Test the integer this rate would be the pull-down OF, and take
        // it only if the exact rational lands back on what was asked for.
        let pulled = (fps * 1.001).rounded()
        if pulled > 0, abs(fps - pulled * 1000 / 1001) < Self.fractionalTolerance {
            self = NDIFrameRate(numerator: Int32(pulled) * 1000,
                                denominator: 1001)
            return
        }
        self = NDIFrameRate(numerator: Int32(fps.rounded()), denominator: 1)
    }
}

/// One NDI source, seen from the app.
///
/// A protocol for the same reason `SRTStreamSending` is one: the real
/// implementation announces a source on the SET NETWORK, and a test suite that
/// did that would be a bad citizen on the shoot's LAN — every run would put a
/// phantom camera in every receiver's source list. Tests inject a fake through
/// `DisplayMirrors.ndiSenderFactory`, which `ControllerHarness` fills in by
/// default so no suite can reach the real one by omission.
///
/// `Sendable` on the same terms the SRT stream is: a sender is BUILT by the
/// factory, which the controller calls on the MainActor, and then used on the
/// mirror's queue. What makes that safe is the confinement rather than any
/// locking — `NDIVideoMirror` is the only thing that ever touches one, on one
/// serial queue, and the implementations say so at their declaration.
protocol NDIVideoSending: AnyObject, Sendable {
    /// The name the source is announced under.
    var sourceName: String { get }
    /// Push one frame. Blocking; called only on `NDIVideoMirror`'s own queue.
    /// Returns false for a frame that was refused (see `CNDSender`).
    @discardableResult
    func send(_ buffer: CVPixelBuffer, rate: NDIFrameRate) -> Bool
    /// Take the source off the network. Idempotent.
    func stop()
}

/// The real sender: a thin Swift face on `CNDSender`, which is a stub in any
/// build without the SDK headers (see `vendor/NDISDK/README.md`).
///
/// `@unchecked Sendable`, and the invariant is the confinement rather than a
/// lock: `CNDSender` owns a runtime instance and is explicitly not thread-safe,
/// and the ONLY thing that calls into one is `NDIVideoMirror`, on
/// `com.takeshot.ndi`, one call at a time. `theSendNeverRunsOnTheCallersQueue`
/// is what holds that.
final class NDISender: NDIVideoSending, @unchecked Sendable {
    private let sender: CNDSender
    let sourceName: String

    /// nil when NDI can be used; otherwise what this build is and what still
    /// works. Structural — a build with no SDK headers, or a machine with no
    /// runtime — as opposed to a sender that could not be created, which is an
    /// error on the call.
    ///
    /// A `BridgeUnavailable` and no longer a String: the bridge states which of
    /// its four causes this is and the app picks the words, so a Russian
    /// operator does not read a localized "Недоступно" over an English
    /// paragraph. The English is still in there and is still what a code this
    /// build does not know renders as.
    static var unavailable: BridgeUnavailable? { .ndi }

    /// The loaded runtime's version, for diagnostics; nil in a stub build.
    static var runtimeVersion: String? { CNDSender.runtimeVersion() }

    /// The factory shape `DisplayMirrors.ndiSenderFactory` overrides.
    static func make(name: String) throws -> NDIVideoSending {
        try NDISender(name: name)
    }

    init(name: String) throws {
        sender = try CNDSender(name: name)
        sourceName = name
    }

    @discardableResult
    func send(_ buffer: CVPixelBuffer, rate: NDIFrameRate) -> Bool {
        sender.sendFrame(buffer, frameRateN: rate.numerator,
                         frameRateD: rate.denominator)
    }

    func stop() {
        sender.stop()
    }
}

/// What Settings shows about the NDI output. Honest by construction: there is
/// no state that means "on" without either a live sender behind it or the reason
/// there is not one.
enum NDIOutputState: Equatable {
    /// The switch is off, which is the default.
    case off
    /// A source is announced and frames are going to it.
    case sending
    /// This build (or this machine) cannot send at all: no SDK headers when it
    /// was compiled, or no runtime installed. Carries what that means.
    ///
    /// Distinct from `failed` because it is not something flicking the switch
    /// again can change, which is why the switch is left exactly where the
    /// operator put it — see `CaptureController.startNDIOutput`.
    ///
    /// The whole `BridgeUnavailable` and not its text, so the row renders in
    /// whatever language the app is in WHEN IT DRAWS. An operator who throws
    /// this switch and then changes the language would otherwise be reading a
    /// paragraph in the language they just left.
    case unavailable(BridgeUnavailable)
    /// The SDK and the runtime are both there and creating the sender failed
    /// anyway (a name already announced by another process, a runtime refusing
    /// the CPU). Carries the reason.
    case failed(String)
}
