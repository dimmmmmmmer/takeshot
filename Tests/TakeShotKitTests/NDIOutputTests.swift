import CNDI
import CaptureCore
import CoreVideo
import Foundation
import Testing

@testable import TakeShotKit

/// A sender that never touches the network.
///
/// The real one announces an NDI source on the LAN the machine is on, which on a
/// shoot is the set network — so this is the only kind of sender a test may have.
/// `ControllerHarness` installs it for every controller it builds; a suite that
/// wants to look at the frames installs its own factory over that one.
///
/// Lock-guarded rather than main-actor-confined for the reason
/// `FakeAudioCaptureDevice` carries a lock: it is called on `NDIVideoMirror`'s
/// queue and read from the test, and TSan aborts a suite on a plain `var`.
final class FakeNDISender: NDISending, @unchecked Sendable {
    /// How many receivers the tests want this source to have. Zero by
    /// default — a source that has just been announced has none, which is the
    /// state most of these tests are in.
    nonisolated(unsafe) var receivers: Int32 = 0
    /// What `send` answers. False is a runtime refusing the frame — the source
    /// stays announced and the receiver goes on looking at the last picture,
    /// which is the failure this flag exists to reproduce.
    nonisolated(unsafe) var acceptsFrames = true
    var connectedReceivers: Int32 { receivers }
    let sourceName: String

    /// One packet of sound as it reached the sender: already de-interleaved,
    /// already float, which is the point — the conversion is above this.
    struct AudioPacket: Sendable {
        var planes: [Float]
        var framesPerChannel: Int
        var channels: Int
        var sampleRate: Int
        /// The label of the queue it arrived on.
        var queue: String

        /// One channel's plane, which is what makes a de-interleave assertion
        /// readable rather than an index expression.
        func plane(_ channel: Int) -> [Float] {
            let start = channel * framesPerChannel
            return Array(planes[start..<(start + framesPerChannel)])
        }
    }

    private let lock = NSLock()
    private var storedFrames: [CVPixelBuffer] = []
    private var storedRates: [NDIFrameRate] = []
    private var storedQueues: [String] = []
    private var storedAudio: [AudioPacket] = []
    private var storedStopped = false

    init(name: String) {
        sourceName = name
    }

    /// The frames that arrived, oldest first.
    var frames: [CVPixelBuffer] {
        lock.withLock { storedFrames }
    }

    /// The rate stated for each of them.
    var rates: [NDIFrameRate] {
        lock.withLock { storedRates }
    }

    /// The label of the queue each `send` ran on. What proves the work is not
    /// on the capture queue — or on the shared encoder's.
    var queues: [String] {
        lock.withLock { storedQueues }
    }

    /// The sound that arrived, oldest first. Separate from `frames` because the
    /// two legs are separate: they arrive on two queues and neither waits for
    /// the other.
    var audio: [AudioPacket] {
        lock.withLock { storedAudio }
    }

    var isStopped: Bool {
        lock.withLock { storedStopped }
    }

    @discardableResult
    func send(_ buffer: CVPixelBuffer, rate: NDIFrameRate) -> Bool {
        guard acceptsFrames else { return false }
        let label = String(cString: __dispatch_queue_get_label(nil))
        lock.withLock {
            storedFrames.append(buffer)
            storedRates.append(rate)
            storedQueues.append(label)
        }
        return true
    }

    @discardableResult
    func send(audio planar: [Float], framesPerChannel: Int, channels: Int,
              sampleRate: Int) -> Bool {
        let label = String(cString: __dispatch_queue_get_label(nil))
        lock.withLock {
            storedAudio.append(AudioPacket(planes: planar,
                                           framesPerChannel: framesPerChannel,
                                           channels: channels,
                                           sampleRate: sampleRate,
                                           queue: label))
        }
        return true
    }

    func stop() {
        lock.withLock { storedStopped = true }
    }
}

/// A sender that parks inside a send for as long as it is told to, with the
/// two legs held INDEPENDENTLY.
///
/// Stands in for the thing NDI's sends really are: two synchronous calls on one
/// sender, each of which compresses before it returns, on a link that may be
/// slow. Two holds rather than one because there are now two claims to make and
/// they are different: that a wedged NDI receiver cannot reach another OUTPUT's
/// queue (`aParkedNDISendDoesNotStallTheSRTLink`), and that inside this one
/// output the picture and the sound cannot hold each other up.
final class BlockingNDISender: NDISending, @unchecked Sendable {
    /// A fake sender nobody is watching: the tests
    /// that use it are about frames, not about the link.
    var connectedReceivers: Int32 { 0 }
    let sourceName = "blocking"
    private let hold: TimeInterval
    private let audioHold: TimeInterval
    private let lock = NSLock()
    private var storedCount = 0
    private var storedAudioCount = 0
    /// Signalled once the first send is INSIDE the block, so a test can wait for
    /// the wedge rather than sleeping and hoping.
    private let entered = DispatchSemaphore(value: 0)
    private let enteredAudio = DispatchSemaphore(value: 0)

    /// `holding` is the picture's hold; `holdingAudio` defaults to none, so
    /// every existing caller wedges exactly what it used to.
    init(holding hold: TimeInterval, holdingAudio audioHold: TimeInterval = 0) {
        self.hold = hold
        self.audioHold = audioHold
    }

    var count: Int { lock.withLock { storedCount } }
    var audioCount: Int { lock.withLock { storedAudioCount } }

    /// Wait for the first send to be in flight; false if it never started.
    func waitUntilInsideSend() -> Bool {
        entered.wait(timeout: .now() + 5) == .success
    }

    func waitUntilInsideAudioSend() -> Bool {
        enteredAudio.wait(timeout: .now() + 5) == .success
    }

    @discardableResult
    func send(_ buffer: CVPixelBuffer, rate: NDIFrameRate) -> Bool {
        lock.withLock { storedCount += 1 }
        entered.signal()
        Thread.sleep(forTimeInterval: hold)
        return true
    }

    @discardableResult
    func send(audio planar: [Float], framesPerChannel: Int, channels: Int,
              sampleRate: Int) -> Bool {
        lock.withLock { storedAudioCount += 1 }
        enteredAudio.signal()
        Thread.sleep(forTimeInterval: audioHold)
        return true
    }

    func stop() {}
}

/// Fixtures for the NDI suites.
enum NDIFixtures {
    /// A display-shaped buffer: 32BGRA, the one format the display path makes.
    static func displayBuffer(width: Int = 64, height: Int = 36,
                              fill: UInt8 = 0x40) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_32BGRA, attrs as CFDictionary,
                            &buffer)
        let result: CVPixelBuffer = try #require(buffer)
        CVPixelBufferLockBaseAddress(result, [])
        if let base = CVPixelBufferGetBaseAddress(result) {
            memset(base, Int32(fill),
                   CVPixelBufferGetBytesPerRow(result) * height)
        }
        CVPixelBufferUnlockBaseAddress(result, [])
        return result
    }

    /// A 16-bit record buffer — the wrong thing to hand a BGRX declaration.
    static func recordBuffer(width: Int = 64, height: Int = 36) throws
        -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_64RGBALE, nil, &buffer)
        let result: CVPixelBuffer = try #require(buffer)
        return result
    }
}

/// NDI states a frame rate as a rational and the rates a set runs at are not
/// integers. A receiver handed 23.976/1 has to guess at the pull-down, and the
/// guess is what shows up as a stutter on a director's monitor.
///
/// This is the one piece of the design SRT deliberately did not inherit —
/// MPEG-TS timestamps on a 90 kHz clock and has no rate field — so it came back
/// with the feature rather than being shared with the transport beside it.
struct NDIFrameRateTests {
    @Test func pullDownRatesAreExactRationals() {
        #expect(NDIFrameRate(fps: 23.976) ==
            NDIFrameRate(fps: 24000.0 / 1001.0))
        #expect(NDIFrameRate(fps: 23.976).numerator == 24000)
        #expect(NDIFrameRate(fps: 23.976).denominator == 1001)
        #expect(NDIFrameRate(fps: 29.97).numerator == 30000)
        #expect(NDIFrameRate(fps: 29.97).denominator == 1001)
        #expect(NDIFrameRate(fps: 59.94).numerator == 60000)
        #expect(NDIFrameRate(fps: 59.94).denominator == 1001)
    }

    /// A board or a sidecar may hand over the rounded form. It means the same
    /// rate, and rounding it back to 24/1 is the bug this catches.
    @Test func aRoundedPullDownRateIsStillAPullDownRate() {
        #expect(NDIFrameRate(fps: 23.98).numerator == 24000)
        #expect(NDIFrameRate(fps: 23.98).denominator == 1001)
        #expect(NDIFrameRate(fps: 29.976).denominator == 1001)
    }

    /// …and the integer rates must NOT be dragged into the 1001 family. 25 is
    /// 0.025 from 25000/1001, which is the tightest of these and the one a
    /// sloppy tolerance breaks first.
    @Test func integerRatesStayIntegers() {
        for fps in [24.0, 25.0, 30.0, 48.0, 50.0, 60.0] {
            let rate = NDIFrameRate(fps: fps)
            #expect(rate.denominator == 1, "\(fps) became a pull-down rate")
            #expect(rate.numerator == Int32(fps))
        }
    }

    @Test func aRateNobodyKnowsFallsBackRatherThanDividingByZero() {
        for fps in [0.0, -1.0, .nan, .infinity, 100_000.0] {
            #expect(NDIFrameRate(fps: fps) == NDIFrameRate.fallback,
                    "\(fps) did not fall back")
            #expect(NDIFrameRate(fps: fps).denominator != 0)
        }
    }
}

/// The frame path: off the caller's queue, latest-wins, and byte for byte what
/// arrived.
struct NDIVideoMirrorTests {
    /// A pass that cannot keep up REPLACES the pending frame rather than
    /// queueing behind it — the feed falls to fewer frames, never to older ones,
    /// which is the only acceptable failure for a monitor. Four frames offered
    /// back to back cost at most two sends, and the LAST one is what went out.
    @Test func theNewestFrameWinsAndTheRestAreDropped() async throws {
        let sender = FakeNDISender(name: "test")
        let mirror = NDIVideoMirror(sender: sender, framesPerSecond: 5)
        var offered: [CVPixelBuffer] = []
        for index in 0..<4 {
            let buffer = try NDIFixtures.displayBuffer(fill: UInt8(index))
            offered.append(buffer)
            mirror.offer(buffer, rate: NDIFrameRate(fps: 25))
        }
        // Two pace intervals: long enough for the immediate pass and one more.
        await ControllerWait.until { sender.frames.count >= 2 }
        try await Task.sleep(for: .milliseconds(500))

        let frames = sender.frames
        #expect(!frames.isEmpty, "not one frame reached the sender")
        #expect(frames.count <= 2,
                "\(frames.count) sends for 4 frames — a queue, not a coalesce")
        #expect(frames.last === offered.last,
                "the frame that went out is not the newest one")
        mirror.stop()
    }

    /// The pace is a ceiling. Only an upper bound is asserted: a loaded machine
    /// can always deliver fewer, and a suite that demanded a floor would be
    /// measuring the runner rather than the mirror.
    @Test func thePaceIsACeiling() async throws {
        let sender = FakeNDISender(name: "test")
        let mirror = NDIVideoMirror(sender: sender, framesPerSecond: 10)
        let buffer = try NDIFixtures.displayBuffer()
        let window = 0.6
        let deadline = Date().addingTimeInterval(window)
        while Date() < deadline {
            mirror.offer(buffer, rate: NDIFrameRate(fps: 25))
            try await Task.sleep(for: .milliseconds(10))
        }
        // 10/s over 0.6 s is 6 sends, +1 for the immediate first pass, +2 slack
        // for a scheduler that fires a pass early on either edge.
        #expect(sender.frames.count <= 9,
                "\(sender.frames.count) sends in \(window)s at a 10/s ceiling")
        mirror.stop()
    }

    /// **The colour declaration, checked by construction.**
    ///
    /// The frames on the wire are BGRX: the display buffer's bytes, full range,
    /// Rec.709 primaries and transfer. That is only true if nothing touches them,
    /// so what this asserts is that the sender is handed the very same buffer
    /// object — no copy, no repack, and above all no CoreImage pass that could
    /// acquire a gamma conversion the way the multiview encoder's once did.
    @Test func theFrameReachesTheSenderUntouched() async throws {
        let sender = FakeNDISender(name: "test")
        let mirror = NDIVideoMirror(sender: sender)
        let buffer = try NDIFixtures.displayBuffer(width: 128, height: 72)
        mirror.offer(buffer, rate: NDIFrameRate(fps: 23.976))
        #expect(await ControllerWait.until { !sender.frames.isEmpty })

        let received: CVPixelBuffer = try #require(sender.frames.first)
        #expect(received === buffer, "the frame was copied or converted")
        #expect(CVPixelBufferGetPixelFormatType(received)
            == kCVPixelFormatType_32BGRA)
        #expect(CVPixelBufferGetWidth(received) == 128)
        #expect(CVPixelBufferGetHeight(received) == 72)
        #expect(sender.rates.first?.numerator == 24000)
        #expect(sender.rates.first?.denominator == 1001)
        mirror.stop()
    }

    /// BGRX over a 16-bit record buffer is not a wrong colour, it is a read past
    /// the end of the plane. The frame is dropped before it costs a queue hop.
    @Test func aFrameInAnotherPixelFormatNeverReachesTheSender() async throws {
        let sender = FakeNDISender(name: "test")
        let mirror = NDIVideoMirror(sender: sender)
        mirror.offer(try NDIFixtures.recordBuffer(),
                     rate: NDIFrameRate(fps: 25))
        try await Task.sleep(for: .milliseconds(200))
        #expect(sender.frames.isEmpty, "a BGRA-only path took a 64RGBALE frame")
        mirror.stop()
    }

    /// The pixel work and the send happen on the mirror's own queue. Offered
    /// from a queue standing in for capture, the send must not have run there:
    /// NDI's send compresses the frame inside the call, and a frame interval
    /// spent doing that on the capture queue is a dropped frame in the file.
    @Test func theSendNeverRunsOnTheCallersQueue() async throws {
        let sender = FakeNDISender(name: "test")
        let mirror = NDIVideoMirror(sender: sender)
        let buffer = try NDIFixtures.displayBuffer()
        let caller = DispatchQueue(label: "takeshot.test.pretend-capture")
        caller.async { mirror.offer(buffer, rate: NDIFrameRate(fps: 25)) }
        #expect(await ControllerWait.until { !sender.queues.isEmpty })

        #expect(sender.queues.allSatisfy { $0 == NDIVideoMirror.queueLabel },
                "the send ran on \(sender.queues)")
        // …and specifically not on the shared encoder's queue, which is the one
        // the OTHER live outputs are on. Two outputs at once share the display
        // handler's dispatch and nothing else.
        #expect(!sender.queues.contains(LiveVideoEncoder.queueLabel),
                "the NDI send ran on the shared encoder's queue")
        mirror.stop()
    }

    /// **Offering costs the caller a dispatch and nothing more, even while a
    /// send is wedged.**
    ///
    /// The case two outputs at once created: NDI's send is synchronous and can
    /// park for as long as its receiver makes it, and the display queue is
    /// shared with the hardware feeder and the H.264 encoder. If `offer` waited
    /// on anything, a slow NDI receiver would be holding up the SRT stream, the
    /// browsers and the DeckLink output all at once — from the display queue,
    /// one hop away from the capture queue that owns the file.
    ///
    /// Measured against the wedge rather than against a clock the runner owns:
    /// the send is held for 1.5 s, and 200 offers made while it is inside that
    /// send have to return in a fraction of it.
    @Test func offeringDoesNotWaitForASendThatHasParked() async throws {
        let sender = BlockingNDISender(holding: 1.5)
        let mirror = NDIVideoMirror(sender: sender, framesPerSecond: 1000)
        let buffer = try NDIFixtures.displayBuffer()
        mirror.offer(buffer, rate: NDIFrameRate(fps: 25))
        #expect(sender.waitUntilInsideSend(), "the send never started")

        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<200 { mirror.offer(buffer, rate: NDIFrameRate(fps: 25)) }
        let elapsed =
            Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        #expect(elapsed < 0.5,
                "200 offers took \(elapsed)s while one send was parked")
        mirror.stop()
    }
}

/// The default name and the stored settings field.
struct NDISettingsFieldTests {
    @Test func theSourceNameDefaultsToTheProjectAndTheCamera() {
        var settings = CaptureSettings()
        settings.naming.projectName = "Dune"
        settings.naming.cameraLabel = "B"
        // No host name in it: NDI announces a source as "MACHINE (name)" and
        // supplies the machine half itself.
        let name = settings.ndi.sourceNameEffective(settings.naming)
        #expect(name == "Dune B")
        #expect(!name.contains(ProcessInfo.processInfo.hostName))
    }

    @Test func anUnnamedProjectStillGetsAName() {
        var settings = CaptureSettings()
        settings.naming.projectName = ""
        settings.naming.cameraLabel = ""
        #expect(settings.ndi.sourceNameEffective(settings.naming) == "TakeShot")
    }

    /// Whitespace is not a name. The field writes whatever is typed, and a
    /// source announced as " " is one nobody can find in a receiver's list.
    @Test func aBlankNameFallsBackToTheDefault() {
        var settings = CaptureSettings()
        settings.naming.projectName = "Dune"
        settings.naming.cameraLabel = "A"
        settings.ndi.sourceName = "   "
        #expect(settings.ndi.sourceNameEffective(settings.naming) == "Dune A")
        settings.ndi.sourceName = "Client feed"
        #expect(settings.ndi.sourceNameEffective(settings.naming)
            == "Client feed")
    }

    @Test func theSwitchIsOffInAFreshInstall() {
        #expect(CaptureSettings().ndi.enabled == nil)
        #expect(CaptureSettings().ndi.sourceName == nil)
    }

    /// Optional like every added field, so a blob written by a build that never
    /// heard of NDI — or by one of the builds that had stopped hearing of it —
    /// still decodes. The two directions of the round trip this record has
    /// actually made are pinned in `ModelSettingsMigrationTests`; this is the
    /// field-level half.
    @Test func settingsWrittenWithoutTheFieldsStillDecode() throws {
        var settings = CaptureSettings()
        settings.naming.projectName = "Dune"
        settings.ndi.enabled = true
        settings.ndi.sourceName = "Client feed"
        let data: Data = try JSONEncoder().encode(settings)
        var raw: [String: Any] = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        raw.removeValue(forKey: "ndiEnabled")
        raw.removeValue(forKey: "ndiSourceName")
        let older: Data = try JSONSerialization.data(withJSONObject: raw)

        let decoded: CaptureSettings =
            try JSONDecoder().decode(CaptureSettings.self, from: older)
        #expect(decoded.ndi.enabled == nil)
        #expect(decoded.ndi.sourceName == nil)
        #expect(decoded.naming.projectName == "Dune")
    }
}
