import CNDI
import CaptureCore
import CoreVideo
import Foundation
import Testing

@testable import TakeShotKit

/// Every sender a controller asked for, in order.
///
/// Lock-guarded: the factory runs on the MainActor but the senders it hands back
/// are read while the mirror's queue is writing into them.
final class NDISenderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storedSenders: [FakeNDISender] = []

    func build(_ name: String) -> FakeNDISender {
        let sender = FakeNDISender(name: name)
        lock.withLock { storedSenders.append(sender) }
        return sender
    }

    var all: [FakeNDISender] { lock.withLock { storedSenders } }
    var names: [String] { all.map(\.sourceName) }
    var latest: FakeNDISender? { all.last }
}

@MainActor
enum NDIProbe {
    /// A controller whose NDI factory records what it built and reaches no
    /// network. `live: true` leaves the synthetic 1080p25 source running, which
    /// is what puts real display frames on the path.
    static func run(live: Bool = false,
                    configure: @escaping (inout CaptureSettings) -> Void
                        = { _ in },
                    _ body: (CaptureController, NDISenderLog) async throws
                        -> Void) async throws {
        let log = NDISenderLog()
        try await ControllerHarness.run(live: live,
                                        configure: configure) { controller, _ in
            controller.mirrors.ndiSenderFactory = { log.build($0) }
            try await body(controller, log)
        }
    }
}

/// The NDI source's life: announced with the switch, dropped with it, and honest
/// about itself when it cannot be had.
@Suite @MainActor
struct NDILifecycleTests {
    @Test func theSwitchIsOffAndNothingIsBuiltUntilItIsThrown() async throws {
        try await NDIProbe.run(live: true) { controller, log in
            #expect(controller.settings.ndi.enabled == nil)
            #expect(controller.mirrors.ndi == nil)
            #expect(controller.mirrors.ndiState == .off)
            // The synthetic source has been running the whole time. An idle
            // feature costs nothing: no sender was ever asked for, so there is
            // nothing on the display path to call.
            try await Task.sleep(for: .milliseconds(300))
            #expect(log.all.isEmpty, "a sender was built with the switch off")
        }
    }

    @Test func theSourceIsAnnouncedAndDroppedWithTheSetting() async throws {
        try await NDIProbe.run { controller, log in
            controller.settings.naming.projectName = "Dune"
            controller.settings.naming.cameraLabel = "B"
            controller.settings.ndi.enabled = true

            #expect(controller.mirrors.ndi != nil)
            #expect(controller.mirrors.ndiState == .sending)
            #expect(log.names == ["Dune B"])

            controller.settings.ndi.enabled = nil
            #expect(controller.mirrors.ndi == nil)
            #expect(controller.mirrors.ndiState == .off)
            #expect(await ControllerWait.until {
                log.latest?.isStopped == true
            }, "the source was left announced")
        }
    }

    /// The end to end path: a frame off the board reaches the NDI source, in the
    /// format and at the rate the wire is in — and NOT on the capture queue.
    @Test func theDisplayFrameReachesTheSource() async throws {
        try await NDIProbe.run(live: true) { controller, log in
            controller.settings.ndi.enabled = true
            let sender = try #require(log.latest)
            #expect(await ControllerWait.until { !sender.frames.isEmpty },
                    "no frame ever reached the NDI source")

            let frame = try #require(sender.frames.first)
            #expect(CVPixelBufferGetPixelFormatType(frame)
                == kCVPixelFormatType_32BGRA)
            #expect(CVPixelBufferGetWidth(frame)
                == SyntheticSignalBackend.format.width)
            #expect(CVPixelBufferGetHeight(frame)
                == SyntheticSignalBackend.format.height)
            // The rate stated is the signal's, as a rational.
            #expect(sender.rates.first == NDIFrameRate(fps: 25))
            // …and the send ran on the mirror's queue. The capture queue owns
            // the per-frame work and an NDI compress on it is a dropped frame in
            // the file.
            #expect(sender.queues.allSatisfy {
                $0 == NDIVideoMirror.queueLabel
            }, "the send ran on \(sender.queues)")
        }
    }

    @Test func nothingReachesTheSourceOnceTheSwitchIsOff() async throws {
        try await NDIProbe.run(live: true) { controller, log in
            controller.settings.ndi.enabled = true
            let sender = try #require(log.latest)
            #expect(await ControllerWait.until { !sender.frames.isEmpty })

            controller.settings.ndi.enabled = nil
            #expect(await ControllerWait.until { sender.isStopped })
            let afterStop = sender.frames.count
            try await Task.sleep(for: .milliseconds(300))
            #expect(sender.frames.count == afterStop,
                    "frames kept going out after the switch went off")
        }
    }

    /// A name change is a re-announce: NDI publishes the name at create time and
    /// cannot rename a live sender. Debounced, so the keystrokes that spell a
    /// name out do not each put a source in every receiver's list.
    @Test func aNameChangeReannouncesTheSourceOnce() async throws {
        try await NDIProbe.run { controller, log in
            controller.settings.ndi.enabled = true
            controller.settings.ndi.sourceName = "Cl"
            controller.settings.ndi.sourceName = "Clie"
            controller.settings.ndi.sourceName = "Client feed"
            #expect(log.names.count == 1,
                    "a sender per keystroke: \(log.names)")

            #expect(await ControllerWait.until { log.names.count == 2 },
                    "the settled name was never announced")
            #expect(log.names.last == "Client feed")
            #expect(log.all.first?.isStopped == true,
                    "the old source was left on the network")
            #expect(controller.mirrors.ndiState == .sending)
        }
    }

    /// A sender that cannot be created — almost always a name another process
    /// has already announced. The switch stays ON, unlike the web remote's:
    /// the fix is to type a different name in the field below the status, and
    /// both the field and the status only exist while the switch is on.
    @Test func aSenderThatCannotBeCreatedIsReported() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.mirrors.ndiSenderFactory = { _ in
                throw NSError(domain: "test", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "source name already in use",
                ])
            }
            controller.settings.ndi.enabled = true

            #expect(controller.mirrors.ndi == nil)
            #expect(controller.mirrors.ndiState
                == .failed("source name already in use"))
            #expect(controller.settings.ndi.enabled == true,
                    "the switch went off and took the name field with it")
            #expect(controller.lastError?.contains("source name already in use")
                == true)
        }
    }

    /// …and the retry: with the switch still on, a new name goes through the
    /// same re-announce path.
    @Test func aNewNameRetriesAfterAFailure() async throws {
        try await ControllerHarness.run { controller, _ in
            let log = NDISenderLog()
            controller.mirrors.ndiSenderFactory = { _ in
                throw NSError(domain: "test", code: 1)
            }
            controller.settings.ndi.enabled = true
            #expect(controller.mirrors.ndi == nil)

            controller.mirrors.ndiSenderFactory = { log.build($0) }
            controller.settings.ndi.sourceName = "Client feed"
            #expect(await ControllerWait.until { controller.mirrors.ndi != nil },
                    "a new name did not retry")
            #expect(log.names == ["Client feed"])
            #expect(controller.mirrors.ndiState == .sending)
        }
    }
}

/// The build most people have, and the only one CI has: no SDK at all.
///
/// Both tests run ONLY in a stub build — which is what they are about, and also
/// what keeps them from announcing a real source the day the headers arrive.
@Suite(.enabled(if: !CNDSender.isSDKAvailable(),
                "this build has the NDI SDK"))
@MainActor
struct NDIStubBuildTests {
    /// The reason has to be an instruction: what to download, and where to put
    /// it. English, like every other bridge error.
    @Test func theStubSaysWhatToInstall() throws {
        let reason = try #require(NDISender.unavailableReason)
        #expect(reason.contains("vendor/NDISDK/include"),
                "the reason does not say where the headers go: \(reason)")
        #expect(reason.contains("ndi.video"),
                "the reason does not say where to get them: \(reason)")
        #expect(NDISender.runtimeVersion == nil)
    }

    /// Switching it on in a build that cannot send says so — and leaves the
    /// switch alone, because no amount of flicking it will change the answer.
    @Test func switchingItOnReportsUnavailable() async throws {
        try await ControllerHarness.run { controller, _ in
            // The harness fakes the sender for every controller it builds;
            // clearing it is what puts the real (stub) one back, which is safe
            // in exactly this build and nowhere else.
            controller.mirrors.ndiSenderFactory = nil
            controller.settings.ndi.enabled = true

            #expect(controller.mirrors.ndi == nil)
            guard case .unavailable(let reason) = controller.mirrors.ndiState else {
                Issue.record("state is \(controller.mirrors.ndiState)")
                return
            }
            #expect(reason.contains("vendor/NDISDK/include"))
            #expect(controller.settings.ndi.enabled == true,
                    "a structural absence turned the operator's switch off")
        }
    }
}
