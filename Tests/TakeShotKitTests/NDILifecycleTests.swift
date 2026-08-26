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
            #expect(controller.mirrors.ndiState == NDIOutputState.off)
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
            #expect(controller.mirrors.ndiState == NDIOutputState.sending)
            #expect(log.names == ["Dune B"])

            controller.settings.ndi.enabled = nil
            #expect(controller.mirrors.ndi == nil)
            #expect(controller.mirrors.ndiState == NDIOutputState.off)
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
            let sender: FakeNDISender = try #require(log.latest)
            #expect(await ControllerWait.until { !sender.frames.isEmpty },
                    "no frame ever reached the NDI source")

            let frame: CVPixelBuffer = try #require(sender.frames.first)
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
            let sender: FakeNDISender = try #require(log.latest)
            #expect(await ControllerWait.until { !sender.frames.isEmpty })

            controller.settings.ndi.enabled = nil
            #expect(await ControllerWait.until { sender.isStopped })
            let afterStop = sender.frames.count
            try await Task.sleep(for: .milliseconds(300))
            #expect(sender.frames.count == afterStop,
                    "frames kept going out after the switch went off")
        }
    }

    /// A shoot that left the switch on gets its source back after a relaunch —
    /// the same promise the web remote and the menu-bar item make, and the
    /// reason `completeStartup` calls `startNDIIfEnabled`.
    ///
    /// Driven by calling the startup step directly rather than by presetting the
    /// switch through the harness's `configure`. That is not fussiness: the
    /// harness installs its fake sender AFTER `init`, and `init` runs the real
    /// startup — so a preset switch would reach the real bridge once, which on a
    /// machine that has the NDI SDK dropped in is an announcement on the set
    /// network. Same reason, same shape, as the SRT factory's.
    @Test func aStoredSwitchAnnouncesTheSourceAtStartup() async throws {
        try await NDIProbe.run { controller, log in
            controller.settings.naming.projectName = "Dune"
            controller.settings.naming.cameraLabel = "C"
            // What a relaunch reads back, without the settings-change path that
            // `theSourceIsAnnouncedAndDroppedWithTheSetting` already covers.
            controller.mirrors.ndiState = .off
            controller.settings.ndi.enabled = true
            controller.stopNDIOutput()
            #expect(log.all.count == 1)

            controller.startNDIIfEnabled()
            #expect(log.names == ["Dune C", "Dune C"],
                    "the stored switch did not announce at startup: \(log.names)")
            #expect(controller.mirrors.ndiState == NDIOutputState.sending)
        }
    }

    /// …and a stored switch that is OFF announces nothing, which is what makes
    /// the previous test about the switch rather than about startup.
    @Test func startupAnnouncesNothingWithTheSwitchOff() async throws {
        try await NDIProbe.run { controller, log in
            controller.startNDIIfEnabled()
            #expect(log.all.isEmpty, "startup announced a source: \(log.names)")
            #expect(controller.mirrors.ndiState == NDIOutputState.off)
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
            #expect(controller.mirrors.ndiState == NDIOutputState.sending)
        }
    }

    /// Renaming the PROJECT re-announces too, and that is what the effective
    /// name being a function of two groups actually buys. The default source
    /// name is the project plus the camera, so a shoot that renames the project
    /// mid-day would otherwise leave a source called after yesterday's job in
    /// every receiver's list.
    @Test func renamingTheProjectReannouncesTheDefaultName() async throws {
        try await NDIProbe.run { controller, log in
            controller.settings.naming.projectName = "Dune"
            controller.settings.naming.cameraLabel = "A"
            controller.settings.ndi.enabled = true
            #expect(log.names == ["Dune A"])

            controller.settings.naming.projectName = "Arrakis"
            #expect(await ControllerWait.until { log.names.count == 2 },
                    "the renamed project never reached the source list")
            #expect(log.names.last == "Arrakis A")
        }
    }

    /// …and a project rename with an explicit source name set does NOT: the
    /// field wins, so the fallback is not consulted and nothing on the network
    /// moves. The other direction of the same rule, and the one that would still
    /// pass if `sourceNameEffective` ignored the naming group entirely.
    @Test func renamingTheProjectLeavesAnExplicitNameAlone() async throws {
        try await NDIProbe.run { controller, log in
            controller.settings.ndi.sourceName = "Client feed"
            controller.settings.ndi.enabled = true
            #expect(log.names == ["Client feed"])

            controller.settings.naming.projectName = "Arrakis"
            try await Task.sleep(for: CaptureController.ndiRenameDebounce
                + .milliseconds(300))
            #expect(log.names == ["Client feed"],
                    "an explicit name was re-announced: \(log.names)")
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
                == NDIOutputState.failed("source name already in use"))
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
            #expect(controller.mirrors.ndiState == NDIOutputState.sending)
        }
    }
}

/// **Two network outputs at once**, which is the case that did not exist while
/// NDI and SRT were alternatives rather than neighbours.
///
/// What has to be true of it is not "both work" — each suite already covers its
/// own — but that they are INDEPENDENT: one display frame feeds both, neither is
/// a consumer of the other, and neither can be delayed by the other going wrong.
/// That independence is structural (NDI takes the display buffer, SRT takes
/// samples off the shared H.264 encoder) and these are what say so out loud.
@Suite(.enabled(if: SRTVideoEncoder.isSupported,
                "no H.264 encoder on this machine"))
@MainActor
struct NDIBesideSRTTests {
    /// Both switched on, both fed, off one display slot. The SRT half is the
    /// shared encoder existing at all; the NDI half is frames arriving.
    @Test func oneDisplayFrameFeedsBothOutputs() async throws {
        try await NDIProbe.run(live: true) { controller, log in
            controller.mirrors.srtStreamFactory = { _ in FakeSRTStream() }
            controller.settings.srt.address = "10.0.0.9"
            controller.settings.srt.enabled = true
            controller.settings.ndi.enabled = true

            #expect(controller.mirrors.srt != nil)
            #expect(controller.mirrors.ndi != nil)
            #expect(controller.mirrors.liveEncoder != nil,
                    "the SRT link did not build the shared encoder")

            let sender: FakeNDISender = try #require(log.latest)
            #expect(await ControllerWait.until { !sender.frames.isEmpty },
                    "the NDI source got nothing while SRT was also on")
            // The NDI sends are on NDI's queue, and specifically not on the one
            // the shared encoder and everything behind it run on.
            #expect(sender.queues.allSatisfy {
                $0 == NDIVideoMirror.queueLabel
            }, "the send ran on \(sender.queues)")
        }
    }

    /// Switching SRT off leaves NDI sending, and the display slot with it.
    ///
    /// The regression this is really about: `stopSRTOutput` calls
    /// `releaseLiveEncoderIfIdle` and then re-wires the mirrors, and
    /// `wireDisplayMirrors` clears the slot when nothing is left. NDI is one of
    /// the things that counts as something being left, and a guard that had only
    /// ever heard of the feeder and the encoder would silently take the NDI
    /// source's frames away as a side effect of a switch it has nothing to do
    /// with.
    @Test func switchingSRTOffLeavesTheNDISourceSending() async throws {
        try await NDIProbe.run(live: true) { controller, log in
            controller.mirrors.srtStreamFactory = { _ in FakeSRTStream() }
            controller.settings.srt.address = "10.0.0.9"
            controller.settings.srt.enabled = true
            controller.settings.ndi.enabled = true
            let sender: FakeNDISender = try #require(log.latest)
            #expect(await ControllerWait.until { !sender.frames.isEmpty })

            controller.settings.srt.enabled = nil
            #expect(controller.mirrors.srt == nil)
            #expect(controller.mirrors.liveEncoder == nil,
                    "the shared encoder outlived the last thing watching it")
            #expect(controller.mirrors.ndi != nil)
            #expect(controller.mirrors.ndiState == NDIOutputState.sending)

            let before = sender.frames.count
            #expect(await ControllerWait.until {
                sender.frames.count > before
            }, "the NDI source stopped when the SRT switch went off")
            #expect(!sender.isStopped)
        }
    }

    /// And the other direction: NDI off leaves the SRT link and its encoder up.
    @Test func switchingNDIOffLeavesTheSRTLinkSending() async throws {
        try await NDIProbe.run(live: true) { controller, log in
            let streams = SRTStreamLog()
            controller.mirrors.srtStreamFactory = { streams.build($0) }
            controller.settings.srt.address = "10.0.0.9"
            controller.settings.srt.enabled = true
            controller.settings.ndi.enabled = true
            #expect(await ControllerWait.until { streams.all.count == 1 })
            let stream: FakeSRTStream = try #require(streams.latest)
            #expect(await ControllerWait.until { !stream.datagrams.isEmpty },
                    "the SRT link got nothing")

            controller.settings.ndi.enabled = nil
            #expect(controller.mirrors.ndi == nil)
            #expect(await ControllerWait.until { log.latest?.isStopped == true })
            #expect(controller.mirrors.srt != nil)
            #expect(controller.mirrors.liveEncoder != nil,
                    "the NDI switch took the shared encoder with it")

            let before = stream.datagrams.count
            #expect(await ControllerWait.until {
                stream.datagrams.count > before
            }, "the SRT link stopped when the NDI switch went off")
        }
    }

    /// **A wedged NDI receiver cannot reach the SRT link.**
    ///
    /// The failure two outputs at once makes possible and the one worth a test
    /// of its own: NDI's send is synchronous and parks inside the call. If the
    /// two outputs shared a queue — or if `offer` waited on anything — a
    /// receiver that stopped acknowledging would stall the transport stream, the
    /// browsers, the hardware output and, one hop up, the display queue itself.
    /// Here the NDI sender is held inside a send for two seconds and the SRT
    /// link has to keep taking datagrams throughout.
    @Test func aParkedNDISendDoesNotStallTheSRTLink() async throws {
        try await ControllerHarness.run(live: true) { controller, _ in
            let streams = SRTStreamLog()
            let blocking = BlockingNDISender(holding: 2)
            controller.mirrors.srtStreamFactory = { streams.build($0) }
            controller.mirrors.ndiSenderFactory = { _ in blocking }
            controller.settings.srt.address = "10.0.0.9"
            controller.settings.srt.enabled = true
            controller.settings.ndi.enabled = true

            #expect(await ControllerWait.until { streams.all.count == 1 })
            let stream: FakeSRTStream = try #require(streams.latest)
            #expect(blocking.waitUntilInsideSend(),
                    "the NDI send never started")

            // The wedge is in flight. Wait out everything that was ALREADY in
            // the encoder before it started, because those datagrams would
            // arrive either way and counting them is how this test passes
            // against a bug — measured: with `offer` made synchronous it did
            // exactly that until this settle was added.
            try await Task.sleep(for: .milliseconds(700))
            let mid = stream.datagrams.count
            // Everything from here is a display frame taken DURING the wedge.
            // The window closes well inside the two seconds the send is held.
            #expect(await ControllerWait.until({
                stream.datagrams.count > mid
            }, timeout: .milliseconds(900)),
                    "the SRT link stalled behind a parked NDI send")
            #expect(blocking.count >= 1)
        }
    }
}

/// The build most people have, and the only one CI has: no SDK at all.
///
/// Both tests run ONLY in a stub build — which is what they are about, and also
/// what keeps them from announcing a real source the day the headers arrive.
@Suite(.enabled(if: !CNDSender.isSDKAvailable(),
                "this machine has the NDI SDK, so the feature is present"))
@MainActor
struct NDIStubBuildTests {
    /// **The reason is written for whoever is really reading it**, and on a
    /// downloaded DMG that is not somebody who can copy headers into a source
    /// tree: a published release is built on a runner with no vendor drops at
    /// all, so every bridge in this app is a stub there by design. So the line
    /// has to say what this build IS, what still works, and only then where a
    /// developer would look.
    @Test func theStubSaysWhatThisBuildIsRatherThanWhatToCopy() throws {
        #expect(CNDSender.isSDKAvailable() == false)
        let reason: String = try #require(NDISender.unavailableReason)
        #expect(reason.contains("NDI SDK"),
                "the reason does not name what is missing: \(reason)")
        // What is true of the app in front of the reader, and what still works
        // without any vendor SDK at all.
        #expect(reason.contains("not available"),
                "the reason does not say the feature is absent: \(reason)")
        #expect(reason.contains("remote"),
                "the reason offers the reader nothing that works: \(reason)")
        // The developer's next step is a file to read, not an instruction the
        // operator cannot carry out.
        #expect(reason.contains("vendor/NDISDK/README.md"),
                "the reason names no file to read: \(reason)")
        #expect(!reason.contains("rebuild"),
                "the reason tells a DMG reader to rebuild: \(reason)")
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
            #expect(reason.contains("NDI SDK"))
            #expect(controller.settings.ndi.enabled == true,
                    "a structural absence turned the operator's switch off")
        }
    }

    /// **`completeStartup` really does run the NDI step**, which is the one
    /// thing `aStoredSwitchAnnouncesTheSourceAtStartup` cannot say: that test
    /// calls `startNDIIfEnabled()` itself, so deleting the call from startup
    /// leaves it green.
    ///
    /// Saying it needs a controller built from a blob that already has the
    /// switch on, and that is only safe HERE. The harness installs its fake
    /// sender after `init`, so a preset switch reaches the real bridge once —
    /// harmless in a build with no NDI SDK, which is exactly what this suite is
    /// gated on, and an announcement on the set network anywhere else. The
    /// observable is the state: startup that ran the step leaves `.unavailable`
    /// (the stub's answer), and startup that skipped it leaves `.off`.
    @Test func startupRunsTheNDIStepForAStoredSwitch() async throws {
        try await ControllerHarness.run(configure: { settings in
            settings.ndi.enabled = true
        }, { controller, _ in
            guard case .unavailable = controller.mirrors.ndiState else {
                let state: String = "\(controller.mirrors.ndiState)"
                Issue.record("startup did not run the NDI step: \(state)")
                return
            }
            #expect(controller.mirrors.ndi == nil)
        })
    }

    /// And nothing else about the app is different. The one thing a stub build
    /// must never do is cost the display path anything: with the switch on and
    /// the feature unavailable there is no mirror, so there is no consumer on
    /// the slot and an idle app still calls nothing per frame.
    @Test func anUnavailableFeatureCostsTheFramePathNothing() async throws {
        try await ControllerHarness.run(live: true) { controller, _ in
            controller.mirrors.ndiSenderFactory = nil
            controller.settings.ndi.enabled = true
            try await Task.sleep(for: .milliseconds(300))
            #expect(controller.mirrors.ndi == nil)
            #expect(controller.mirrors.liveEncoder == nil,
                    "an unavailable feature built an encoder")
        }
    }
}
