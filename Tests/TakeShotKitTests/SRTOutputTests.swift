import CSRT
import CaptureCore
import CoreVideo
import Foundation
import Testing

@testable import TakeShotKit

/// A link that never touches a network.
///
/// The real one puts UDP on the LAN the machine is on, which on a shoot is the set
/// network — so this is the only kind of link a test may have, and unlike NDI's
/// fake it is not merely belt and braces: a machine with `brew install srt` on it
/// has the real bridge compiled and it works. `ControllerHarness` installs one for
/// every controller it builds; a suite that wants to look at the datagrams
/// installs its own factory over that.
///
/// Lock-guarded rather than main-actor-confined for the reason
/// `FakeAudioCaptureDevice` carries a lock: it is called on `SRTMirror`'s
/// queue and read from the test, and TSan aborts a suite on a plain `var`.
final class FakeSRTStream: SRTStreamSending, @unchecked Sendable {
    private let lock = NSLock()
    private var storedDatagrams: [Data] = []
    private var storedQueues: [String] = []
    private var storedOpens = 0
    private var storedClosed = false
    private var storedOutcomes: [SRTSendOutcome]
    private var storedOpenFailures: [SRTStreamError]

    /// `outcomes` is consumed one entry per send and the last one repeats, so a
    /// suite writes the story it wants — "two frames through, then the link goes".
    /// `openFailures` does the same for `open`.
    init(outcomes: [SRTSendOutcome] = [.sent],
         openFailures: [SRTStreamError] = []) {
        storedOutcomes = outcomes
        storedOpenFailures = openFailures
    }

    var datagrams: [Data] { lock.withLock { storedDatagrams } }
    /// The label of the queue each send ran on. What proves the work is not on the
    /// capture queue.
    var queues: [String] { lock.withLock { storedQueues } }
    var opens: Int { lock.withLock { storedOpens } }
    var isClosed: Bool { lock.withLock { storedClosed } }

    func open() throws {
        let failure: SRTStreamError? = lock.withLock {
            storedOpens += 1
            return storedOpenFailures.isEmpty ? nil
                : storedOpenFailures.removeFirst()
        }
        if let failure { throw failure }
    }

    func send(_ datagram: Data) -> SRTSendOutcome {
        let label = String(cString: __dispatch_queue_get_label(nil))
        return lock.withLock {
            storedQueues.append(label)
            let outcome = storedOutcomes.count > 1
                ? storedOutcomes.removeFirst() : (storedOutcomes.first ?? .sent)
            if outcome == .sent { storedDatagrams.append(datagram) }
            return outcome
        }
    }

    var lastSendError: String? { "the fake link says so" }

    func close() {
        lock.withLock { storedClosed = true }
    }
}

/// Every event a mirror reported, in order.
final class SRTEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [SRTMirror.Event] = []

    func record(_ event: SRTMirror.Event) {
        lock.withLock { stored.append(event) }
    }

    var all: [SRTMirror.Event] { lock.withLock { stored } }
}

enum SRTFixtures {
    /// A display-shaped buffer: 32BGRA, the one format the display path makes.
    static func displayBuffer(width: Int = 128, height: Int = 72,
                              fill: UInt8 = 0x40) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_32BGRA, attrs as CFDictionary,
                            &buffer)
        let result = try #require(buffer)
        CVPixelBufferLockBaseAddress(result, [])
        if let base = CVPixelBufferGetBaseAddress(result) {
            memset(base, Int32(fill),
                   CVPixelBufferGetBytesPerRow(result) * height)
        }
        CVPixelBufferUnlockBaseAddress(result, [])
        return result
    }

    /// A 16-bit record buffer — the wrong thing to hand an encoder built for the
    /// display path's one format.
    static func recordBuffer(width: Int = 128, height: Int = 72) throws
        -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_64RGBALE, nil, &buffer)
        return try #require(buffer)
    }

    static let endpoint = SRTEndpoint(role: .caller, address: "10.0.0.9",
                                      port: 9000, latencyMs: 120,
                                      passphrase: nil)

    /// A mirror over a fake link, with its events recorded, and the shared
    /// encoder in front of it.
    ///
    /// The two travel together because the mirror is a CONSUMER now: the frames
    /// are offered to the encoder, and the mirror only ever sees the samples it
    /// fans out. `SRTRig` is what keeps the suites below reading as they did —
    /// offer a frame, look at the link — while the encode has moved out from
    /// under them.
    static func rig(_ stream: SRTStreamSending, log: SRTEventLog,
                    endpoint: SRTEndpoint = endpoint,
                    framesPerSecond: Double = LiveVideoEncoder.framesPerSecond)
        -> SRTRig {
        let encoder = LiveVideoEncoder(bitsPerSecond: 4_000_000,
                                       framesPerSecond: framesPerSecond)
        return SRTRig(
            encoder: encoder, log: log,
            mirror: SRTMirror(endpoint: endpoint, encoder: encoder,
                                   factory: { _ in stream },
                                   onEvent: { log.record($0) }))
    }
}

/// One shared encoder with one SRT mirror on it, driven as a unit.
struct SRTRig {
    let encoder: LiveVideoEncoder
    let log: SRTEventLog
    let mirror: SRTMirror

    /// Open the link and come back once the mirror has SETTLED — either
    /// subscribed to the encoder, or having reported why it could not be.
    ///
    /// **The wait is what the old design got for free, and losing it silently
    /// was the one hazard in moving the encode out.** The mirror used to own
    /// its encoder, so one serial queue ordered `start()`'s connect ahead of
    /// every frame offered after it. Now the encode is shared and on a queue of
    /// its own, so a frame offered in the same breath as `start()` can arrive
    /// while the link is still opening — and it is dropped, because the mirror
    /// has not subscribed yet. In the app that costs one frame at open and the
    /// next one is 1/60 s behind it; in a test that offers exactly one frame it
    /// costs the whole test, intermittently and only on a loaded machine. It
    /// cost one, in a coverage run.
    func start() {
        mirror.start()
        let deadline = Date().addingTimeInterval(5)
        while !encoder.hasSinks, log.all.isEmpty, Date() < deadline {
            usleep(2_000)
        }
    }

    func offer(_ buffer: CVPixelBuffer, framesPerSecond: Double) {
        encoder.offer(buffer, framesPerSecond: framesPerSecond)
    }

    func stop() {
        mirror.stop()
        encoder.stop()
    }
}

/// The two numbers the mirror's behaviour is argued from. Their own suite because
/// they are arithmetic and must be checked on every machine, including one with no
/// H.264 encoder on it.
@Suite struct SRTMirrorConstantTests {
    /// The ceiling exists for the bursts the display path can produce (an aid
    /// switched on over a paused picture, a playback scrub), not to throttle a
    /// signal — so it has to sit above every rate the app captures.
    @Test func theCeilingIsAboveEveryRateTheAppCaptures() {
        #expect(LiveVideoEncoder.framesPerSecond >= 60)
        #expect(LiveVideoEncoder.minimumInterval <= 1.0 / 60)
        for fps in [23.976, 24.0, 25.0, 29.97, 30.0, 50.0, 59.94, 60.0] {
            #expect(1 / fps >= LiveVideoEncoder.minimumInterval,
                    "\(fps) would be throttled by the ceiling")
        }
    }

    /// The backoff is bounded on both ends: quick enough that a receiver reopened
    /// by hand comes back while the operator is still looking, slow enough that a
    /// network that is simply not there costs one attempt per five seconds.
    @Test func theReconnectBackoffIsBoundedBothWays() {
        #expect(SRTMirror.reconnectDelay == 1)
        #expect(SRTMirror.reconnectCeiling == 5)
        #expect(SRTMirror.reconnectDelay < SRTMirror.reconnectCeiling)
    }
}

/// **An idle set encodes nothing**, which is the property the whole shared-encoder
/// design is arranged around — and the one that made a test flake when it was
/// first put in, so it is worth pinning as arithmetic rather than as timing.
///
/// Nobody watching means no `VTCompressionSession` is ever created at all: not a
/// session sitting idle, not a session encoding into a sink that discards. The
/// consequence a caller has to know about is on the other side of the same
/// coin — a frame offered while nothing is subscribed is DROPPED, not held, so
/// whoever subscribes gets the next frame rather than the last one.
@Suite(.enabled(if: SRTVideoEncoder.isSupported,
                "no H.264 encoder on this machine"))
struct LiveVideoEncoderIdleTests {
    @Test func nothingIsEncodedWhileNothingIsWatching() async throws {
        let encoder = LiveVideoEncoder(bitsPerSecond: 4_000_000)
        defer { encoder.stop() }
        let buffer = try SRTFixtures.displayBuffer()
        for _ in 0..<5 {
            encoder.offer(buffer, framesPerSecond: 25)
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(!encoder.hasSinks)
        #expect(encoder.appliedBitsPerSecond == nil,
                "a session was built for nobody")
    }

    /// And the moment something IS watching, the next frame reaches it.
    @Test func theFirstFrameAfterASinkArrivesReachesIt() async throws {
        let encoder = LiveVideoEncoder(bitsPerSecond: 4_000_000)
        defer { encoder.stop() }
        let samples = SampleCounter()
        encoder.addSink(samples) { _ in samples.count() }
        let buffer = try SRTFixtures.displayBuffer()
        let deadline = Date().addingTimeInterval(5)
        while samples.total == 0, Date() < deadline {
            encoder.offer(buffer, framesPerSecond: 25)
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(samples.total > 0, "a subscribed sink got nothing")
        #expect(encoder.appliedBitsPerSecond == 4_000_000)
    }
}

/// Samples that reached a sink. Its identity is the sink's key, so it is a
/// class; the count is touched from VideoToolbox's thread, so it is locked.
final class SampleCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    func count() { lock.withLock { stored += 1 } }
    var total: Int { lock.withLock { stored } }
}

/// The frame path: off the caller's queue, latest-wins, and never able to hold it
/// up.
///
/// Gated on a real H.264 encoder, because these drive one. Everything the mirror
/// does with a frame goes through VideoToolbox, so a machine that cannot encode
/// cannot exercise the path at all — and a suite that failed there would be
/// reporting the machine rather than the code.
@Suite(.enabled(if: SRTVideoEncoder.isSupported,
                "no H.264 encoder on this machine"))
struct SRTMirrorTests {
    /// A pass that cannot keep up REPLACES the pending frame rather than queueing
    /// behind it — the feed falls to fewer frames, never to older ones, which is
    /// the only acceptable failure for a monitor. Four frames offered back to back
    /// cost at most two encodes.
    @Test func theNewestFrameWinsAndTheRestAreDropped() async throws {
        let stream = FakeSRTStream()
        let log = SRTEventLog()
        let mirror = SRTFixtures.rig(stream, log: log, framesPerSecond: 5)
        mirror.start()
        #expect(await ControllerWait.until { stream.opens == 1 })
        for index in 0..<4 {
            mirror.offer(try SRTFixtures.displayBuffer(fill: UInt8(index)),
                         framesPerSecond: 25)
        }
        #expect(await ControllerWait.until { !stream.datagrams.isEmpty },
                "not one datagram reached the link")
        try await Task.sleep(for: .milliseconds(500))
        // Two pace intervals at 5/s: the immediate pass and one more. Each frame
        // is one access unit and a 128x72 frame fits one datagram, so the
        // datagram count IS the frame count here.
        #expect(stream.datagrams.count <= 2,
                "\(stream.datagrams.count) frames went out for 4 offered")
        mirror.stop()
    }

    /// The pace is a ceiling. Only an upper bound is asserted: a loaded machine
    /// can always deliver fewer, and a suite that demanded a floor would be
    /// measuring the runner rather than the mirror.
    @Test func thePaceIsACeiling() async throws {
        let stream = FakeSRTStream()
        let log = SRTEventLog()
        let mirror = SRTFixtures.rig(stream, log: log, framesPerSecond: 10)
        mirror.start()
        #expect(await ControllerWait.until { stream.opens == 1 })
        let buffer = try SRTFixtures.displayBuffer()
        let deadline = Date().addingTimeInterval(0.6)
        while Date() < deadline {
            mirror.offer(buffer, framesPerSecond: 25)
            try await Task.sleep(for: .milliseconds(10))
        }
        // 10/s over 0.6 s is 6 encodes, +1 for the immediate first pass, +2 slack
        // for a scheduler that fires a pass early on either edge.
        #expect(stream.datagrams.count <= 9,
                "\(stream.datagrams.count) frames in 0.6s at a 10/s ceiling")
        mirror.stop()
    }

    /// A frame in another pixel format is dropped before it costs a queue hop.
    /// The encoder is built for the display path's one format, and a 16-bit
    /// record buffer handed to it is not a wrong colour — it is a read past the
    /// end of the plane.
    @Test func aFrameInAnotherPixelFormatNeverReachesTheLink() async throws {
        let stream = FakeSRTStream()
        let log = SRTEventLog()
        let mirror = SRTFixtures.rig(stream, log: log)
        mirror.start()
        #expect(await ControllerWait.until { stream.opens == 1 })
        mirror.offer(try SRTFixtures.recordBuffer(), framesPerSecond: 25)
        try await Task.sleep(for: .milliseconds(300))
        #expect(stream.datagrams.isEmpty, "a BGRA-only path took a 64RGBALE frame")
        mirror.stop()
    }

    /// **Everything happens on the mirror's own queue.** The encode compresses a
    /// frame and the send touches a socket; a frame interval spent on either on
    /// the capture queue is a dropped frame in the file.
    @Test func theWorkNeverRunsOnTheCallersQueue() async throws {
        let stream = FakeSRTStream()
        let log = SRTEventLog()
        let mirror = SRTFixtures.rig(stream, log: log)
        mirror.start()
        #expect(await ControllerWait.until { stream.opens == 1 })
        let buffer = try SRTFixtures.displayBuffer()
        let caller = DispatchQueue(label: "takeshot.test.pretend-capture")
        caller.async { mirror.offer(buffer, framesPerSecond: 25) }
        #expect(await ControllerWait.until { !stream.queues.isEmpty },
                "no datagram ever reached the link")
        #expect(stream.queues.allSatisfy { $0 == SRTMirror.queueLabel },
                "the send ran on \(stream.queues)")
        mirror.stop()
    }

    /// **`offer` returns before the work does, and that is what the frame path
    /// depends on.** Ordering rather than a clock: the fake link blocks inside
    /// `send` until the test lets it go, and `offer` has to have returned while it
    /// is still in there.
    @Test func offerReturnsWhileTheSendIsStillInFlight() throws {
        let stream = BlockingSRTStream()
        let log = SRTEventLog()
        let mirror = SRTFixtures.rig(stream, log: log)
        mirror.start()
        let buffer = try SRTFixtures.displayBuffer()
        mirror.offer(buffer, framesPerSecond: 25)
        let started: DispatchTimeoutResult =
            stream.entered.wait(timeout: .now() + 10)
        #expect(started == .success, "the link was never asked to send")
        // The mirror's queue is now parked inside that send. A second offer has to
        // come straight back regardless: it is an async dispatch, not a wait.
        let returned = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            mirror.offer(buffer, framesPerSecond: 25)
            returned.signal()
        }
        let came: DispatchTimeoutResult = returned.wait(timeout: .now() + 2)
        #expect(came == .success,
                "offer parked behind a send that had not finished")
        stream.release()
        mirror.stop()
    }

    /// A link that stops taking bytes is reopened, with the operator told once.
    @Test func aBrokenLinkIsReportedAndReopened() async throws {
        let stream = FakeSRTStream(outcomes: [.sent, .broken])
        let log = SRTEventLog()
        let mirror = SRTFixtures.rig(stream, log: log)
        mirror.start()
        #expect(await ControllerWait.until { stream.opens == 1 })
        for _ in 0..<3 {
            mirror.offer(try SRTFixtures.displayBuffer(), framesPerSecond: 25)
            try await Task.sleep(for: .milliseconds(60))
        }
        #expect(await ControllerWait.until {
            log.all.contains(SRTMirror.Event.lost("the fake link says so"))
        }, "the loss was never reported: \(log.all)")
        // …and it tries again rather than sitting there. The first backoff is a
        // second, so this is an I/O-sized wait rather than an interactive one.
        #expect(await ControllerWait.until { stream.opens >= 2 },
                "the link was never reopened")
        mirror.stop()
    }

    /// A configuration failure is NOT retried. Retrying it forever would hide the
    /// one thing the operator can act on.
    @Test func aRefusedLinkIsNotRetried() async throws {
        let stream = FakeSRTStream(
            openFailures: [.configuration("cannot listen on port 9000")])
        let log = SRTEventLog()
        let mirror = SRTFixtures.rig(stream, log: log)
        mirror.start()
        #expect(await ControllerWait.until {
            log.all.contains(SRTMirror.Event
                .refused("cannot listen on port 9000"))
        }, "the refusal was never reported: \(log.all)")
        try await Task.sleep(for: .milliseconds(1500))
        #expect(stream.opens == 1,
                "a refused configuration was retried \(stream.opens) times")
        mirror.stop()
    }

    /// A listener with nobody dialled in says so, and says it once. Frames are
    /// dropped meanwhile rather than queued: a receiver that connects in an hour
    /// wants the picture from then, not the hour before it.
    @Test func aListenerWithNoReceiverWaitsWithoutComplaining() async throws {
        let stream = FakeSRTStream(outcomes: [.noPeer])
        let log = SRTEventLog()
        let mirror = SRTFixtures.rig(
            stream, log: log,
            endpoint: SRTEndpoint(role: .listener, address: "", port: 9000,
                                  latencyMs: 120, passphrase: nil))
        mirror.start()
        for _ in 0..<3 {
            mirror.offer(try SRTFixtures.displayBuffer(), framesPerSecond: 25)
            try await Task.sleep(for: .milliseconds(60))
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(stream.datagrams.isEmpty)
        #expect(log.all == [SRTMirror.Event.waiting],
                "a waiting listener reported \(log.all)")
        mirror.stop()
    }

    /// Dropped datagrams are not a state change. A link that cannot carry the
    /// bitrate drops steadily, and a status row that changed on every frame would
    /// re-render the settings window for news the operator cannot use.
    @Test func aFullSendBufferIsNotReportedAsAFailure() async throws {
        let stream = FakeSRTStream(outcomes: [.dropped])
        let log = SRTEventLog()
        let mirror = SRTFixtures.rig(stream, log: log)
        mirror.start()
        #expect(await ControllerWait.until { stream.opens == 1 })
        for _ in 0..<3 {
            mirror.offer(try SRTFixtures.displayBuffer(), framesPerSecond: 25)
            try await Task.sleep(for: .milliseconds(60))
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(log.all == [SRTMirror.Event.opened],
                "a full send buffer reported \(log.all)")
        #expect(!stream.isClosed, "a full send buffer closed the link")
        mirror.stop()
    }

    /// **The stream clock only ever goes forward, reconnect included.**
    ///
    /// The PTS comes from the mirror's own monotonic clock rather than from
    /// anything on the frame, and a reset to zero on a reopened link is the kind of
    /// regression that passes every other test in this file: the datagrams are the
    /// right size, the tables are there, the link takes them. A receiver whose own
    /// clock has already moved past the timestamps it is now being handed discards
    /// frames until it catches up, which reads as a freeze rather than as an error.
    @Test func theStreamClockOnlyGoesForwardAcrossAReconnect() async throws {
        let stream = FakeSRTStream(outcomes: [.sent, .broken, .sent])
        let log = SRTEventLog()
        let mirror = SRTFixtures.rig(stream, log: log, framesPerSecond: 20)
        mirror.start()
        #expect(await ControllerWait.until { stream.opens == 1 })
        let buffer = try SRTFixtures.displayBuffer()
        for _ in 0..<20 {
            mirror.offer(buffer, framesPerSecond: 25)
            try await Task.sleep(for: .milliseconds(120))
        }
        #expect(await ControllerWait.until { stream.opens >= 2 },
                "the link never reconnected, so nothing was proved")
        let stamps: [Int64] = MPEGTSFixtures.timestamps(stream.datagrams)
        #expect(stamps.count >= 2,
                "\(stamps.count) access units either side of the reconnect")
        #expect(stamps == stamps.sorted(),
                "the stream clock went backwards: \(stamps)")
        #expect(Set(stamps).count == stamps.count,
                "two access units share a timestamp: \(stamps)")
        mirror.stop()
    }

    @Test func stoppingClosesTheLinkAndSilencesLaterFrames() async throws {
        let stream = FakeSRTStream()
        let log = SRTEventLog()
        let mirror = SRTFixtures.rig(stream, log: log)
        mirror.start()
        #expect(await ControllerWait.until { stream.opens == 1 })
        mirror.stop()
        #expect(await ControllerWait.until { stream.isClosed })

        mirror.offer(try SRTFixtures.displayBuffer(), framesPerSecond: 25)
        try await Task.sleep(for: .milliseconds(300))
        #expect(stream.datagrams.isEmpty, "a stopped mirror still sent")
    }

    /// The ceiling exists for the bursts the display path can produce (an aid
    /// switched on over a paused picture, a playback scrub), not to throttle a
    /// signal — so it has to sit above every rate the app captures.
    @Test func theCeilingIsAboveEveryRateTheAppCaptures() {
        #expect(LiveVideoEncoder.framesPerSecond >= 60)
        #expect(LiveVideoEncoder.minimumInterval <= 1.0 / 60)
        for fps in [23.976, 24.0, 25.0, 29.97, 30.0, 50.0, 59.94, 60.0] {
            #expect(1 / fps >= LiveVideoEncoder.minimumInterval,
                    "\(fps) would be throttled by the ceiling")
        }
    }

    /// The backoff is bounded on both ends: quick enough that a receiver reopened
    /// by hand comes back while the operator is still looking, slow enough that a
    /// network that is simply not there costs one attempt per five seconds.
    @Test func theReconnectBackoffIsBoundedBothWays() {
        #expect(SRTMirror.reconnectDelay == 1)
        #expect(SRTMirror.reconnectCeiling == 5)
        #expect(SRTMirror.reconnectDelay < SRTMirror.reconnectCeiling)
    }
}

/// A link whose send parks until the test lets it go. Only
/// `offerReturnsWhileTheSendIsStillInFlight` wants this, and it wants it to prove
/// an ORDERING rather than a duration.
final class BlockingSRTStream: SRTStreamSending, @unchecked Sendable {
    /// Signalled as the first send begins.
    let entered = DispatchSemaphore(value: 0)
    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var parked = false

    func open() throws {}

    /// Only the FIRST send parks. A latch rather than a gate every send waits on,
    /// so releasing it once does not leave the rest of the suite paying a timeout
    /// per datagram.
    func send(_ datagram: Data) -> SRTSendOutcome {
        let first: Bool = lock.withLock {
            guard !parked else { return false }
            parked = true
            return true
        }
        if first {
            entered.signal()
            _ = gate.wait(timeout: .now() + 10)
        }
        return .sent
    }

    func release() {
        gate.signal()
    }

    var lastSendError: String? { nil }

    func close() {
        gate.signal()
    }
}

/// The build most people have, and the only one CI has: no libsrt at all.
///
/// Runs ONLY in a stub build — which is what it is about, and also what keeps it
/// from asserting the wrong half on a development machine that has the headers.
@Suite(.enabled(if: !CSRTSender.isSDKAvailable(), "this build has libsrt"))
struct SRTStubBuildTests {
    /// The reason has to be an instruction: what to install, and where to put it.
    /// English, like every other bridge error.
    @Test func theStubSaysWhatToInstall() throws {
        let reason: String = try #require(SRTStream.unavailable?.english)
        #expect(reason.contains("brew install srt"),
                "the reason does not say how to get it: \(reason)")
        #expect(reason.contains("vendor/SRTSDK/include"),
                "the reason does not say where the headers go: \(reason)")
        #expect(SRTStream.runtimeVersion == nil)
    }
}
