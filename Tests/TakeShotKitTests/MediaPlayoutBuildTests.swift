import CaptureCore
import CoreVideo
import Foundation
import Testing

@testable import TakeShotKit

/// Building the hardware mirror, and which producer feeds it once it exists.
///
/// `MediaPlayoutRoutingTests` covers the side of the switch where there is no
/// output at all. This is the other side: `PlayoutFeeder.factory` is replaced
/// with one that hands back a feeder on a fake board, so the output mode the
/// controller asks for, the fallback when the board refuses it, and the routing
/// that follows the viewer are all assertable without a DeckLink.
@Suite @MainActor struct MediaPlayoutBuildTests {
    /// One output mode the controller asked the factory for.
    private struct Mode: Equatable {
        var board: String
        var width: Int
        var height: Int
        var rate: Double
    }

    /// What the controller asked the factory for, and what it got.
    private final class Requests {
        var modes: [Mode] = []
        var outputs: [FakePlayoutOutput] = []
    }

    /// Install a factory for `body` and put the real one back — a fake left in
    /// place would disarm the hardware output for the whole suite run.
    ///
    /// `failing` is how many opens refuse before one succeeds: 0 — the first
    /// mode is accepted, 1 — only the 1080p25 fallback is.
    private func withFakeBoard(
        failing: Int = 0,
        _ body: (Requests) async throws -> Void) async throws {
        struct NoSuchMode: Error {}
        let requests = Requests()
        var refusalsLeft = failing
        let previous = PlayoutFeeder.factory
        PlayoutFeeder.factory = { board, width, height, rate in
            requests.modes.append(Mode(board: board, width: width,
                                       height: height, rate: rate))
            if refusalsLeft > 0 {
                refusalsLeft -= 1
                throw NoSuchMode()
            }
            let output = FakePlayoutOutput(width: width, height: height)
            requests.outputs.append(output)
            return PlayoutFeeder(output: output)
        }
        defer { PlayoutFeeder.factory = previous }
        try await body(requests)
    }

    /// The output mode follows the live signal, and only the board's own ID goes
    /// to the SDK — the `decklink:` prefix is this app's routing tag and the
    /// board has never heard of it.
    @Test func theOutputModeFollowsTheLiveSignal() async throws {
        try await withFakeBoard { requests in
            try await ControllerHarness.run { controller, _ in
                controller.settings.monitorDeviceID = "decklink:UltraStudio4KMini"

                #expect(requests.modes.count == 1)
                #expect(requests.modes.first?.board == "UltraStudio4KMini",
                        "the routing prefix was handed to the SDK")
                #expect(controller.mirrors.playout != nil)
                #expect(controller.lastError == nil)
            }
        }
    }

    /// With no signal yet the mode is the universal 1080p25 raster rather than
    /// nothing: the director's monitor comes up before the camera does.
    @Test func withNoSignalTheOutputComesUpAt1080p25() async throws {
        try await withFakeBoard { requests in
            try await ControllerHarness.run { controller, _ in
                #expect(controller.signalFormat == nil)
                controller.settings.monitorDeviceID = "decklink:board"

                let asked = try #require(requests.modes.first)
                #expect(asked.width == 1920)
                #expect(asked.height == 1080)
                #expect(asked.rate == 25)
                let feeder = try #require(controller.mirrors.playout)
                #expect(feeder.outputSize == (1920, 1080))
            }
        }
    }

    /// A board that cannot do the signal's raster gets asked for 1080p25 instead,
    /// and the operator is told nothing — the mirror works, the frames are
    /// scaled, and there is nothing for them to do about it.
    @Test func aRefusedModeFallsBackTo1080p25() async throws {
        try await withFakeBoard(failing: 1) { requests in
            try await ControllerHarness.run { controller, _ in
                // a raster no HD-only output can take
                controller.signalFormat = MediaFixtures.format(
                    width: 4096, height: 2160, frameRate: 47.95, timecodeFPS: 48)
                controller.settings.monitorDeviceID = "decklink:board"

                #expect(requests.modes.count == 2, "the fallback was not attempted")
                #expect(requests.modes.first?.width == 4096)
                #expect(requests.modes.last?.width == 1920)
                #expect(requests.modes.last?.rate == 25)
                let feeder = try #require(controller.mirrors.playout)
                #expect(feeder.outputSize == (1920, 1080))
                #expect(controller.lastError == nil,
                        "the fallback reported: \(controller.lastError ?? "")")
            }
        }
    }

    /// Both attempts refused: no mirror, and the operator has to be told.
    /// Silently showing nothing on the director's monitor is the failure this
    /// error exists for.
    @Test func aBoardThatRefusesEverythingIsReported() async throws {
        try await withFakeBoard(failing: 2) { requests in
            try await ControllerHarness.run { controller, _ in
                controller.settings.monitorDeviceID = "decklink:board"

                #expect(requests.modes.count == 2)
                #expect(controller.mirrors.playout == nil)
                #expect(controller.lastError?.hasPrefix("Output:") == true,
                        "the dead output said: \(controller.lastError ?? "nothing")")
            }
        }
    }

    /// In record mode the mirror is fed by the LIVE pipeline, and by nothing
    /// else. Two sources at once puts two pictures on the director's monitor.
    ///
    /// Asserted by outcome rather than by reading a handler slot: the live signal
    /// runs, and frames have to arrive at the board on their own.
    @Test func inRecordModeTheLiveSignalFeedsTheMirrorAlone() async throws {
        try await withFakeBoard { requests in
            try await ControllerHarness.run(live: true) { controller, _ in
                // the format first: an output built before one is known is
                // rebuilt when it arrives, and the board under test would be
                // the one that was already torn down
                await ControllerWait.until { controller.signalFormat != nil }
                controller.viewerMode = .record
                controller.settings.monitorDeviceID = "decklink:board"
                let board = try #require(requests.outputs.last)

                #expect(await ControllerWait.until { !board.displayed.isEmpty },
                        "no live frame reached the board")
                #expect(controller.playbackTap.displayFrameHandler == nil,
                        "the tap fed the mirror alongside the live pipeline")
            }
        }
    }

    /// A format arriving after the output was opened rebuilds it at the new
    /// raster, and only then. The output mode follows the signal, so a monitor
    /// that came up on the 1080p25 default before the camera was rolling has to
    /// follow it up to UHD — and the old board has to be released on the way.
    @Test func aFormatArrivingAfterTheOutputRebuildsIt() async throws {
        try await withFakeBoard { requests in
            try await ControllerHarness.run(live: true) { controller, _ in
                controller.settings.monitorDeviceID = "decklink:board"
                let firstBoard = try #require(requests.outputs.first)
                #expect(firstBoard.outputWidth == 1920)

                #expect(await ControllerWait.until { requests.modes.count > 1 },
                        "the arriving format did not rebuild the output")
                #expect(firstBoard.stops >= 1, "the first board was left open")
                let asked = try #require(requests.modes.last)
                #expect(asked.width == controller.signalFormat?.width)
                #expect(asked.height == controller.signalFormat?.height)
            }
        }
    }

    /// In review the tap takes over, and its frames really do reach the board —
    /// the handler is wired to the feeder, not merely installed. The capture is
    /// stopped first, so the only thing that can put a frame on the wire is the
    /// tap.
    @Test func inReviewTheTapsFramesReachTheBoard() async throws {
        try await withFakeBoard { requests in
            try await ControllerHarness.run { controller, _ in
                controller.settings.monitorDeviceID = "decklink:board"
                controller.viewerMode = .playback
                let feeder = try #require(controller.mirrors.playout)
                let board = try #require(requests.outputs.first)
                #expect(board.displayed.isEmpty)

                controller.playbackTap.attachStill(
                    MediaFixtures.pixelBuffer(level: 0x40, width: 320, height: 180))
                controller.playbackTap.queue.sync {}
                feeder.settle()

                #expect(!board.displayed.isEmpty,
                        "the tap's frames never reached the output")
            }
        }
    }

    /// Back in record mode the tap is disconnected: a still pushed into it does
    /// NOT reach the board. Deterministic rather than a wall-clock window — both
    /// queues are drained, so a frame that was going to arrive has arrived.
    @Test func aStaleTapHandlerIsNotLeftFeedingTheMirror() async throws {
        try await withFakeBoard { requests in
            try await ControllerHarness.run { controller, _ in
                controller.settings.monitorDeviceID = "decklink:board"
                controller.viewerMode = .playback
                let feeder = try #require(controller.mirrors.playout)
                let board = try #require(requests.outputs.first)

                controller.viewerMode = .record
                controller.playbackTap.attachStill(
                    MediaFixtures.pixelBuffer(level: 0x40, width: 320, height: 180))
                controller.playbackTap.queue.sync {}
                feeder.settle()

                #expect(board.displayed.isEmpty,
                        "the tap kept feeding the mirror after the viewer left review")
            }
        }
    }

    /// Choosing a different output tears the old one down. A feeder left running
    /// keeps a board open and keeps pushing frames into it.
    @Test func rebuildingStopsThePreviousOutput() async throws {
        try await withFakeBoard { requests in
            try await ControllerHarness.run { controller, _ in
                controller.settings.monitorDeviceID = "decklink:first"
                let first = try #require(requests.outputs.first)
                #expect(first.stops == 0)

                controller.settings.monitorDeviceID = "decklink:second"
                #expect(first.stops == 1, "the first output was left running")
                #expect(requests.outputs.count == 2)
            }
        }
    }

    /// Turning the output off releases the board and takes every handler with
    /// it — a producer still holding one is pushing frames into a torn-down
    /// feeder.
    @Test func clearingTheOutputReleasesTheBoard() async throws {
        try await withFakeBoard { requests in
            try await ControllerHarness.run { controller, _ in
                controller.settings.monitorDeviceID = "decklink:board"
                let board = try #require(requests.outputs.first)

                controller.settings.monitorDeviceID = nil

                #expect(board.stops == 1)
                #expect(controller.mirrors.playout == nil)
                #expect(controller.playbackTap.displayFrameHandler == nil)
            }
        }
    }
}
