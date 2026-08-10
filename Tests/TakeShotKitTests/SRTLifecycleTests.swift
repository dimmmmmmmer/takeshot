import CSRT
import CaptureCore
import CoreVideo
import Foundation
import Testing

@testable import TakeShotKit

/// Every link a controller asked for, in order.
///
/// Lock-guarded: the factory runs on the mirror's queue while the test reads it.
final class SRTStreamLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storedStreams: [FakeSRTStream] = []
    private var storedEndpoints: [SRTEndpoint] = []
    private let outcomes: [SRTSendOutcome]

    init(outcomes: [SRTSendOutcome] = [.sent]) {
        self.outcomes = outcomes
    }

    func build(_ endpoint: SRTEndpoint) -> FakeSRTStream {
        let stream = FakeSRTStream(outcomes: outcomes)
        lock.withLock {
            storedStreams.append(stream)
            storedEndpoints.append(endpoint)
        }
        return stream
    }

    var all: [FakeSRTStream] { lock.withLock { storedStreams } }
    var endpoints: [SRTEndpoint] { lock.withLock { storedEndpoints } }
    var latest: FakeSRTStream? { all.last }
}

@MainActor
enum SRTProbe {
    /// A controller whose SRT factory records what it built and reaches no
    /// network. `live: true` leaves the synthetic 1080p25 source running, which is
    /// what puts real display frames on the path.
    static func run(live: Bool = false, outcomes: [SRTSendOutcome] = [.sent],
                    configure: @escaping (inout CaptureSettings) -> Void = { _ in },
                    _ body: (CaptureController, SRTStreamLog) async throws -> Void)
        async throws {
        let log = SRTStreamLog(outcomes: outcomes)
        try await ControllerHarness.run(live: live,
                                        configure: configure) { controller, _ in
            controller.mirrors.srtStreamFactory = { log.build($0) }
            try await body(controller, log)
        }
    }

    /// The settings a caller needs to be startable at all.
    static func caller(_ settings: inout CaptureSettings) {
        settings.srt.address = "10.0.0.9"
    }
}

/// The SRT link's life, from the controller's side: opened with the switch,
/// dropped with it, honest about itself when it cannot be had, and — the point of
/// the whole design — unable to touch a take when it goes.
@Suite(.enabled(if: SRTVideoEncoder.isSupported,
                "no H.264 encoder on this machine"))
@MainActor
struct SRTLifecycleTests {
    @Test func theSwitchIsOffAndNothingIsBuiltUntilItIsThrown() async throws {
        try await SRTProbe.run(live: true) { controller, log in
            #expect(controller.settings.srt.enabled == nil)
            #expect(controller.mirrors.srt == nil)
            #expect(controller.mirrors.srtState == SRTOutputState.off)
            // The synthetic source has been running the whole time. An idle
            // feature costs nothing: no link was ever asked for, so there is
            // nothing on the display path to call and no encoder anywhere.
            try await Task.sleep(for: .milliseconds(300))
            #expect(log.all.isEmpty, "a link was opened with the switch off")
        }
    }

    @Test func theLinkIsOpenedAndDroppedWithTheSetting() async throws {
        try await SRTProbe.run { controller, log in
            controller.settings.srt.address = "10.0.4.21"
            controller.settings.srt.port = 9312
            controller.settings.srt.latencyMs = 240
            controller.settings.srt.enabled = true

            #expect(controller.mirrors.srt != nil)
            #expect(controller.mirrors.srtEndpoint?.url == "srt://10.0.4.21:9312")
            #expect(await ControllerWait.until { log.all.count == 1 },
                    "no link was opened")
            let endpoint: SRTEndpoint = try #require(log.endpoints.first)
            #expect(endpoint.role == SRTRole.caller)
            #expect(endpoint.address == "10.0.4.21")
            #expect(endpoint.port == 9312)
            #expect(endpoint.latencyMs == 240)
            #expect(await ControllerWait.until {
                controller.mirrors.srtState == SRTOutputState.sending
            }, "the state stayed \(controller.mirrors.srtState)")

            controller.settings.srt.enabled = nil
            #expect(controller.mirrors.srt == nil)
            #expect(controller.mirrors.srtState == SRTOutputState.off)
            #expect(controller.mirrors.srtEndpoint == nil)
            #expect(await ControllerWait.until { log.latest?.isClosed == true },
                    "the link was left open")
        }
    }

    /// The end to end path: a frame off the board is encoded, packetised and
    /// handed to the link — and NOT on the capture queue.
    @Test func theDisplayFrameReachesTheLinkAsATransportStream() async throws {
        try await SRTProbe.run(live: true,
                               configure: SRTProbe.caller) { controller, log in
            controller.settings.srt.enabled = true
            #expect(await ControllerWait.until { log.latest != nil })
            let stream: FakeSRTStream = try #require(log.latest)
            #expect(await ControllerWait.untilWritten { !stream.datagrams.isEmpty },
                    "no datagram ever reached the link")

            // Every datagram is a whole number of transport packets at the size
            // the socket was configured for, and every packet is a packet.
            #expect(stream.datagrams.allSatisfy {
                $0.count == MPEGTSMuxer.datagramLength
            }, "a datagram was not 1316 bytes")
            let first: Data = try #require(stream.datagrams.first)
            #expect(first[first.startIndex] == MPEGTSMuxer.syncByte)
            // …and it happened on the mirror's queue. The capture queue owns the
            // per-frame work and an H.264 encode on it is a dropped frame in the
            // file.
            #expect(stream.queues.allSatisfy { $0 == SRTVideoMirror.queueLabel },
                    "the send ran on \(stream.queues)")
        }
    }

    @Test func nothingReachesTheLinkOnceTheSwitchIsOff() async throws {
        try await SRTProbe.run(live: true,
                               configure: SRTProbe.caller) { controller, log in
            controller.settings.srt.enabled = true
            #expect(await ControllerWait.until { log.latest != nil })
            let stream: FakeSRTStream = try #require(log.latest)
            #expect(await ControllerWait.untilWritten { !stream.datagrams.isEmpty })

            controller.settings.srt.enabled = nil
            #expect(await ControllerWait.until { stream.isClosed })
            let after: Int = stream.datagrams.count
            try await Task.sleep(for: .milliseconds(400))
            #expect(stream.datagrams.count == after,
                    "datagrams kept going out after the switch went off")
        }
    }

    /// **A caller with no address never opens a socket.** The operator is told, in
    /// their own language, and the switch stays ON so the field to fix it is still
    /// on screen.
    @Test func aCallerWithNoAddressIsReportedRatherThanDialled() async throws {
        try await SRTProbe.run { controller, log in
            controller.settings.srt.enabled = true
            #expect(controller.mirrors.srt == nil)
            #expect(log.all.isEmpty, "a socket was opened with no address")
            guard case .failed(let reason) = controller.mirrors.srtState else {
                Issue.record("state is \(controller.mirrors.srtState)")
                return
            }
            #expect(reason == L("srt_needs_address"))
            #expect(controller.settings.srt.enabled == true,
                    "the switch went off and took the address field with it")
        }
    }

    /// …and the same for a passphrase SRT would refuse, which is the case an
    /// operator would otherwise never learn about: five characters typed, an
    /// unencrypted stream sent.
    @Test func aPassphraseTooShortIsReportedRatherThanIgnored() async throws {
        try await SRTProbe.run(configure: SRTProbe.caller) { controller, log in
            controller.settings.srt.passphrase = "short"
            controller.settings.srt.enabled = true
            #expect(log.all.isEmpty, "a socket was opened with a bad passphrase")
            guard case .failed(let reason) = controller.mirrors.srtState else {
                Issue.record("state is \(controller.mirrors.srtState)")
                return
            }
            #expect(reason.contains("10"),
                    "the reason does not say how long it has to be: \(reason)")
        }
    }

    /// An edit is one rebuild, not one per keystroke. There is no way to re-point a
    /// live SRT socket, so each write would otherwise open a link at an address
    /// half typed.
    @Test func anEditRebuildsTheLinkOnce() async throws {
        try await SRTProbe.run(configure: SRTProbe.caller) { controller, log in
            controller.settings.srt.enabled = true
            #expect(await ControllerWait.until { log.all.count == 1 })
            controller.settings.srt.address = "10.0.4."
            controller.settings.srt.address = "10.0.4.2"
            controller.settings.srt.address = "10.0.4.21"
            #expect(log.all.count == 1, "a link per keystroke: \(log.endpoints)")

            #expect(await ControllerWait.until { log.all.count == 2 },
                    "the settled address was never opened")
            #expect(log.endpoints.last?.address == "10.0.4.21")
            #expect(log.all.first?.isClosed == true,
                    "the old link was left open")
        }
    }

    /// A bitrate change is a rebuild too: the encoder is built for one.
    @Test func aBitrateChangeRebuildsTheEncoder() async throws {
        try await SRTProbe.run(configure: SRTProbe.caller) { controller, log in
            controller.settings.srt.enabled = true
            #expect(await ControllerWait.until { log.all.count == 1 })
            controller.settings.srt.bitrateMbps = 20
            #expect(await ControllerWait.until { log.all.count == 2 },
                    "a bitrate change did not rebuild the link")
        }
    }

    /// **A dead link is a notice and a reconnect, and it does not toast.** On a
    /// venue network the receiver is closed half the day; a banner per drop would
    /// sit over the picture during a take, repeatedly, for a condition that
    /// resolves itself.
    @Test func aLostLinkIsShownInTheRowAndNotAsAToast() async throws {
        try await SRTProbe.run(live: true, outcomes: [.sent, .broken],
                               configure: SRTProbe.caller) { controller, log in
            controller.settings.srt.enabled = true
            #expect(await ControllerWait.untilWritten {
                if case .reconnecting = controller.mirrors.srtState { return true }
                return false
            }, "the loss never reached the row: \(controller.mirrors.srtState)")
            #expect(controller.lastError == nil,
                    "a lost link toasted: \(controller.lastError ?? "")")
            // …and it opens a new one rather than sitting there.
            #expect(await ControllerWait.untilWritten { log.all.count >= 2 },
                    "the link was never reopened")
        }
    }

    /// **…and it cannot touch a take.** A link that fails on every datagram, for
    /// the whole length of a recording, and the take still records and finalizes.
    ///
    /// This is the assertion the whole arrangement exists for. `ChromaKeyIntegrityTests`
    /// and `AssistIntegrityTests` do the same job for the display tools: state the
    /// thing that must not happen, and make the code prove it rather than argue it.
    @Test func aLinkThatFailsOnEveryDatagramDoesNotCostTheTake() async throws {
        try await SRTProbe.run(live: true, outcomes: [.broken],
                               configure: SRTProbe.caller) { controller, log in
            controller.settings.srt.enabled = true
            #expect(await ControllerWait.untilWritten { log.all.count >= 1 })

            controller.toggleManualRecord()
            #expect(await ControllerWait.until { controller.isRecording },
                    "the take never started")
            try await Task.sleep(for: .milliseconds(600))
            controller.toggleManualRecord()
            #expect(await ControllerWait.untilWritten { !controller.takes.isEmpty },
                    "the take never finalized with a dead SRT link")
            let take: Take = try #require(controller.takes.first)
            #expect(!take.url.lastPathComponent.contains("FAILED"),
                    "the take came out as \(take.url.lastPathComponent)")
            #expect(controller.persistentAlert == nil,
                    "a dead SRT link raised a recording alarm")
        }
    }

    /// A configuration the socket refuses DOES toast, because nothing improves
    /// until somebody is told — and the switch stays on so the fix is reachable.
    @Test func aRefusedConfigurationToastsAndLeavesTheSwitchAlone() async throws {
        try await SRTProbe.run(configure: SRTProbe.caller) { controller, _ in
            controller.mirrors.srtStreamFactory = { _ in
                FakeSRTStream(openFailures: [
                    .configuration("cannot listen on port 9000"),
                ])
            }
            controller.settings.srt.enabled = true
            #expect(await ControllerWait.until {
                controller.mirrors.srtState
                    == SRTOutputState.failed("cannot listen on port 9000")
            }, "state is \(controller.mirrors.srtState)")
            #expect(controller.lastError?.contains("cannot listen") == true)
            #expect(controller.settings.srt.enabled == true,
                    "a refused configuration turned the operator's switch off")
        }
    }

    /// A listener needs no address, binds every interface, and says it is waiting
    /// rather than failing while nobody has dialled in.
    @Test func aListenerWaitsForTheReceiverWithoutComplaining() async throws {
        try await SRTProbe.run(outcomes: [.noPeer]) { controller, log in
            controller.settings.srt.role = SRTRole.listener.rawValue
            controller.settings.srt.enabled = true
            #expect(await ControllerWait.until { log.all.count == 1 })
            #expect(log.endpoints.first?.role == SRTRole.listener)
            #expect(controller.mirrors.srtEndpoint?.url == "srt://:9000")
            #expect(await ControllerWait.until {
                controller.mirrors.srtState == SRTOutputState.starting
            }, "state is \(controller.mirrors.srtState)")
            #expect(controller.lastError == nil)
        }
    }
}

/// The build most people have, and the only one CI has: no libsrt at all.
///
/// Runs ONLY in a stub build — which is what it is about, and also what keeps it
/// from opening a real socket on a machine that has the headers.
@Suite(.enabled(if: !CSRTSender.isSDKAvailable(), "this build has libsrt"))
@MainActor
struct SRTStubBuildLifecycleTests {
    /// Switching it on in a build that cannot send says so — and leaves the switch
    /// alone, because no amount of flicking it will change the answer.
    @Test func switchingItOnReportsUnavailable() async throws {
        try await ControllerHarness.run { controller, _ in
            // The harness fakes the link for every controller it builds; clearing
            // it is what puts the real (stub) one back, which is safe in exactly
            // this build and nowhere else.
            controller.mirrors.srtStreamFactory = nil
            controller.settings.srt.address = "10.0.0.9"
            controller.settings.srt.enabled = true

            #expect(controller.mirrors.srt == nil)
            guard case .unavailable(let reason) = controller.mirrors.srtState else {
                Issue.record("state is \(controller.mirrors.srtState)")
                return
            }
            #expect(reason.contains("vendor/SRTSDK/include"))
            #expect(controller.settings.srt.enabled == true,
                    "a structural absence turned the operator's switch off")
        }
    }
}
