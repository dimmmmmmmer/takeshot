import CaptureCore
import CoreVideo
import Foundation
import Testing

@testable import TakeShotKit

/// Every fake board the playout factory has built, newest last.
///
/// A box rather than the board itself, because the feeder is REBUILT on the
/// first format change (`bindPipeline`) and the synthetic backend announces one
/// shortly after the harness has stopped it. Holding the first board and
/// asserting on it counts frames on an output the app stopped using — which is a
/// test that fails for a reason that has nothing to do with the change.
@MainActor
final class GridBoards {
    var all: [FakePlayoutOutput] = []
    var latest: FakePlayoutOutput? { all.last }
}

/// A sync-play comparison with a board on the other end of the mirror, and the
/// two readings its suites take of it.
///
/// Shared by `ControllerGridOutputTests` (the picture that goes out, and what it
/// costs) and `ControllerGridExitTests` (what the surfaces do when the
/// comparison ends), because both need the identical session and the difference
/// between them is only which end of it they look at.
@MainActor
enum GridOutputProbe {
    /// `parked` is whether a take is left open in the single player underneath
    /// the grid — the ordinary way in (review one, then select four) against the
    /// way in that leaves nothing behind it (select four from the panel without
    /// opening one). The two differ in exactly one thing and it is what happens
    /// when the comparison ENDS. The body is handed the scratch root as well,
    /// because a comparison can also be started over a RAW clip and that clip
    /// has to be written somewhere.
    static func withGridAndBoard(
        tiles: Int = 2, parked: Bool = true, board: Bool = true,
        _ body: @MainActor (CaptureController, SyncPlayModel, GridBoards, URL)
            async throws -> Void) async throws {
        let boards = GridBoards()
        let previous = PlayoutFeeder.factory
        PlayoutFeeder.factory = { _, width, height, _ in
            let output = FakePlayoutOutput(width: width, height: height)
            boards.all.append(output)
            return PlayoutFeeder(output: output)
        }
        defer { PlayoutFeeder.factory = previous }

        try await ControllerHarness.run { controller, root in
            MediaFixtures.silence(controller)
            let takes = try GridFixture.seedTakes(controller, in: root,
                                                  count: tiles)
            controller.viewerMode = .playback
            if parked {
                controller.playbackURL = takes[0].url
                controller.playbackFPS = 25
            }
            if board {
                controller.settings.capture.monitorDeviceID = "decklink:board"
                try #require(controller.mirrors.playout != nil,
                             "the fake board did not come up")
                // Let the one format-change rebuild land before anything is
                // counted. Bounded, and it does not matter which way it goes:
                // the assertions read `boards.latest`, so this only stops a
                // rebuild from landing in the MIDDLE of a count.
                _ = await ControllerWait.until({ boards.all.count > 1 },
                                               timeout: .milliseconds(600))
            }
            controller.selectedItems = Set(takes.map(\.url))
            controller.startSyncPlay()
            defer { controller.endSyncPlay() }
            let model = try #require(controller.syncPlay)
            try await body(controller, model, boards, root)
        }
    }

    /// A flat frame offered into one tile's display slot, exactly as that tile's
    /// tap does when it delivers.
    ///
    /// `decorated` and `clean` are the same buffer on purpose — that is what a
    /// tile really produces, because it has no assist stage and no viewing LUT
    /// for the two to come apart over.
    static func deliver(_ model: SyncPlayModel, tile: Int, code: UInt8,
                        width: Int = 320, height: Int = 180) {
        let buffer = MediaFixtures.pixelBuffer(level: code, width: width,
                                               height: height)
        model.tiles[tile].tap.displayFrameHandler?(
            LiveFrame(decorated: buffer, clean: buffer))
    }

    /// The red channel of one pixel. The feeder rebuilds anything that is not
    /// the output's own raster, so the suites sample by FRACTION of the frame.
    nonisolated static func red(of buffer: CVPixelBuffer, atX x: Int,
                                y: Int) -> Int {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return -1 }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let pixel = base.advanced(by: y * stride + x * 4)
            .assumingMemoryBound(to: UInt8.self)
        return Int(pixel[2]) // BGRA
    }
}
