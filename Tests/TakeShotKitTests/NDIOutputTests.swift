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
final class FakeNDISender: NDIVideoSending, @unchecked Sendable {
    let sourceName: String

    private let lock = NSLock()
    private var storedFrames: [CVPixelBuffer] = []
    private var storedRates: [NDIFrameRate] = []
    private var storedQueues: [String] = []
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
    /// on the capture queue.
    var queues: [String] {
        lock.withLock { storedQueues }
    }

    var isStopped: Bool {
        lock.withLock { storedStopped }
    }

    @discardableResult
    func send(_ buffer: CVPixelBuffer, rate: NDIFrameRate) -> Bool {
        let label = String(cString: __dispatch_queue_get_label(nil))
        lock.withLock {
            storedFrames.append(buffer)
            storedRates.append(rate)
            storedQueues.append(label)
        }
        return true
    }

    func stop() {
        lock.withLock { storedStopped = true }
    }
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
        let result = try #require(buffer)
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
        return try #require(buffer)
    }
}

/// NDI states a frame rate as a rational and the rates a set runs at are not
/// integers. A receiver handed 23.976/1 has to guess at the pull-down, and the
/// guess is what shows up as a stutter on a director's monitor.
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

        let received = try #require(sender.frames.first)
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
        mirror.stop()
    }

    @Test func stoppingTakesTheSourceDownAndSilencesLaterFrames() async throws {
        let sender = FakeNDISender(name: "test")
        let mirror = NDIVideoMirror(sender: sender)
        mirror.stop()
        #expect(await ControllerWait.until { sender.isStopped })

        mirror.offer(try NDIFixtures.displayBuffer(),
                     rate: NDIFrameRate(fps: 25))
        try await Task.sleep(for: .milliseconds(200))
        #expect(sender.frames.isEmpty, "a stopped mirror still sent a frame")
    }
}

/// The default name and the stored settings field.
struct NDISettingsFieldTests {
    @Test func theSourceNameDefaultsToTheProjectAndTheCamera() {
        var settings = CaptureSettings()
        settings.projectName = "Dune"
        settings.cameraLabel = "B"
        // No host name in it: NDI announces a source as "MACHINE (name)" and
        // supplies the machine half itself.
        #expect(settings.ndiSourceNameEffective == "Dune B")
        #expect(!settings.ndiSourceNameEffective.contains(
            ProcessInfo.processInfo.hostName))
    }

    @Test func anUnnamedProjectStillGetsAName() {
        var settings = CaptureSettings()
        settings.projectName = ""
        settings.cameraLabel = ""
        #expect(settings.ndiSourceNameEffective == "TakeShot")
    }

    /// Whitespace is not a name. The field writes whatever is typed, and a
    /// source announced as " " is one nobody can find in a receiver's list.
    @Test func aBlankNameFallsBackToTheDefault() {
        var settings = CaptureSettings()
        settings.projectName = "Dune"
        settings.cameraLabel = "A"
        settings.ndiSourceName = "   "
        #expect(settings.ndiSourceNameEffective == "Dune A")
        settings.ndiSourceName = "Client feed"
        #expect(settings.ndiSourceNameEffective == "Client feed")
    }

    @Test func theSwitchIsOffInAFreshInstall() {
        #expect(CaptureSettings().ndiEnabled == nil)
        #expect(CaptureSettings().ndiSourceName == nil)
    }

    /// Optional like every added field, so a blob written by a build that never
    /// heard of NDI still decodes.
    @Test func settingsWrittenBeforeTheFieldExistedStillDecode() throws {
        var settings = CaptureSettings()
        settings.projectName = "Dune"
        settings.ndiEnabled = true
        settings.ndiSourceName = "Client feed"
        let data = try JSONEncoder().encode(settings)
        var raw = try #require(try JSONSerialization.jsonObject(with: data)
            as? [String: Any])
        raw.removeValue(forKey: "ndiEnabled")
        raw.removeValue(forKey: "ndiSourceName")
        let older = try JSONSerialization.data(withJSONObject: raw)

        let decoded = try JSONDecoder().decode(CaptureSettings.self, from: older)
        #expect(decoded.ndiEnabled == nil)
        #expect(decoded.ndiSourceName == nil)
        #expect(decoded.projectName == "Dune")
    }
}
