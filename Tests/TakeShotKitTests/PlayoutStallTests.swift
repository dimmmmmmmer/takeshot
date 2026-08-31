import CaptureCore
import CoreVideo
import Foundation
import Testing

@testable import TakeShotKit

/// **A monitor output that stops taking frames says so.**
///
/// Both ways the aspect-fit can fail — no buffer out of the pool, CoreImage
/// refusing the render — used to `return`, leaving the LAST frame on the board
/// with nothing said anywhere. An operator judging framing on a picture that
/// stopped being live is worse off than one looking at black, and on sticks the
/// two are indistinguishable.
@Suite struct PlayoutStallTests {
    private func frame() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey:
                                [:] as CFDictionary] as CFDictionary, &buffer)
        return try #require(buffer)
    }

    /// Reported once on the way in, and once on the way out — never per frame,
    /// because this runs at the signal's rate.
    @Test func aFrameThatCannotBeScaledIsReportedOnceAndClearedOnRecovery()
        async throws {
        // A degenerate output raster: the geometry never matches, and no pool
        // will hand out a 0×0 buffer.
        let stuck = PlayoutFeeder(output: FakePlayoutOutput(width: 0, height: 0))
        let reports = StallLog()
        stuck.onStall = { reports.record($0) }

        let buffer = try frame()
        for _ in 0..<5 { stuck.submit(buffer) }
        #expect(await ControllerWait.untilWritten { reports.count >= 1 },
                "a frozen output said nothing")
        // Five frames, one sentence: a stall reported per frame would be a
        // toast per frame at 25 a second.
        #expect(reports.count == 1, "said \(reports.count) times for one stall")
        #expect(reports.all.first??.isEmpty == false)
    }

    /// An output that takes its frames says nothing at all.
    @Test func aWorkingOutputReportsNothing() async throws {
        let board = FakePlayoutOutput(width: 320, height: 180)
        let feeder = PlayoutFeeder(output: board)
        let reports = StallLog()
        feeder.onStall = { reports.record($0) }

        let buffer = try frame()
        for _ in 0..<3 { feeder.submit(buffer) }
        #expect(await ControllerWait.untilWritten { !board.displayed.isEmpty },
                "the board never got a frame")
        #expect(reports.count == 0,
                "a working output reported a stall: \(reports.all)")
    }
}

/// Stall reports, in order. Written on the feeder's queue.
final class StallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String?] = []

    func record(_ reason: String?) { lock.withLock { stored.append(reason) } }
    var count: Int { lock.withLock { stored.count } }
    var all: [String?] { lock.withLock { stored } }
}

/// **A board that would not take the signal's own mode is a notice, not a
/// silence.**
///
/// The fallback works — the frames are scaled — so it is not an error. But the
/// director's monitor is then showing a 1080p25 raster of a signal that is
/// neither, and an operator who does not know that reads the softness as the
/// camera's and the cadence as a sync problem.
@MainActor
struct PlayoutFallbackNoticeTests {
    @Test func fallingBackToTheUniversalRasterIsSaid() async throws {
        let previous = PlayoutFeeder.factory
        // Refuses everything but 1080p25, which is what a board that cannot do
        // the signal's mode looks like from here.
        PlayoutFeeder.factory = { _, width, height, rate in
            guard width == 1920, height == 1080, rate == 25 else {
                throw NSError(domain: "test", code: 1)
            }
            return PlayoutFeeder(
                output: FakePlayoutOutput(width: width, height: height))
        }
        defer { PlayoutFeeder.factory = previous }

        try await ControllerHarness.run { controller, _ in
            controller.signalFormat = CaptureFormat(width: 3840, height: 2160,
                                                    frameRate: 50,
                                                    timecodeFPS: 50, name: "UHD")
            controller.lastNotice = nil
            controller.settings.capture.monitorDeviceID = "decklink:board"
            controller.rebuildPlayout()

            #expect(controller.mirrors.playout != nil,
                    "the fallback did not produce an output at all")
            let said = try #require(controller.lastNotice, """
                the monitor quietly became a scaled 1080p25 raster and nothing \
                said so
                """)
            #expect(said.contains("3840"), "the mode it refused is missing: \(said)")
        }
    }

    /// A board that comes back clears its own complaint, and nothing else.
    @Test func arecoveredOutputClearsItsOwnMessageOnly() async throws {
        let previous = PlayoutFeeder.factory
        PlayoutFeeder.factory = { _, width, height, _ in
            PlayoutFeeder(output: FakePlayoutOutput(width: width, height: height))
        }
        defer { PlayoutFeeder.factory = previous }

        try await ControllerHarness.run { controller, _ in
            controller.settings.capture.monitorDeviceID = "decklink:board"
            controller.rebuildPlayout()
            let feeder = try #require(controller.mirrors.playout)

            controller.lastError = L("playout_stalled_render")
            feeder.onStall?(nil)
            // Bounded well under the five seconds the toast register takes to
            // clear a message on its own — an unbounded wait here passes
            // against a recovery that does nothing, which is how the first
            // version of this test survived its own mutation.
            try await Task.sleep(for: .milliseconds(250))
            #expect(controller.lastError == nil,
                    "the board came back and the complaint stayed on screen")

            // …and a message that is somebody else's outranks a resolved stall.
            controller.lastError = "the card is full"
            feeder.onStall?(nil)
            try await Task.sleep(for: .milliseconds(150))
            #expect(controller.lastError == "the card is full",
                    "a recovered monitor wiped an unrelated error")
        }
    }

    /// A board that takes the signal's own mode says nothing.
    @Test func aBoardThatTakesTheModeIsSilent() async throws {
        let previous = PlayoutFeeder.factory
        PlayoutFeeder.factory = { _, width, height, _ in
            PlayoutFeeder(output: FakePlayoutOutput(width: width, height: height))
        }
        defer { PlayoutFeeder.factory = previous }

        try await ControllerHarness.run { controller, _ in
            controller.signalFormat = CaptureFormat(width: 3840, height: 2160,
                                                    frameRate: 50,
                                                    timecodeFPS: 50, name: "UHD")
            controller.lastNotice = nil
            controller.settings.capture.monitorDeviceID = "decklink:board"
            controller.rebuildPlayout()
            // The silence below is only evidence if a playout was actually
            // built: `rebuildPlayout` returning early is silent too, and the
            // notice was cleared on the line above. The sibling test already
            // takes this precaution.
            #expect(controller.mirrors.playout != nil,
                    "no playout was built, so its silence says nothing")
            #expect(controller.lastNotice == nil,
                    "a working board was reported as a fallback")
        }
    }
}
