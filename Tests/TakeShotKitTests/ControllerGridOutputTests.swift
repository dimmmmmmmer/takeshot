import AVFoundation
import CaptureCore
import CoreVideo
import Foundation
import Testing

@testable import TakeShotKit

/// **What goes out while the operator is comparing takes.**
///
/// `ControllerGridSweepTests` is the sweep that found every place a grid changed
/// the right answer INSIDE the app — a marker written into a parked take, a
/// scope tracing it, a badge stating its raster. This is the one it left
/// unfixed on purpose and said why: the hardware monitor, the SDI output, NDI,
/// SRT and the fullscreen player all showed that same parked take, because the
/// grid existed only as a SwiftUI tree of per-tile mounts and there was no grid
/// PICTURE anywhere to hand out.
///
/// There is one now, and it is `MultiviewComposer` — the same composer the
/// `LivePicture.grid` video track already uses, so the arrangement a browser
/// watching the camera grid sees and the arrangement a director watching a
/// comparison sees come from one definition rather than two.
///
/// The tiles are driven through the very closure the app installs on each
/// tile's tap (`tile.tap.displayFrameHandler`), not through a re-implementation
/// of it: the fixture takes are one-byte placeholders and their AVPlayers never
/// turn ready, so a real decode is not available here — but the wiring under
/// test is the wiring that runs.
@Suite @MainActor struct ControllerGridOutputTests {
    // MARK: - the picture the director gets

    /// **The headline: the board shows the grid, not the take underneath it.**
    ///
    /// Both halves matter and they fail differently. The parked tap must be
    /// DISCONNECTED — left wired it would push its frozen frame in between the
    /// grid's, which is a director's monitor flickering between a comparison and
    /// a still — and the frame that arrives must actually be the composed grid,
    /// checked by reading the tiles out of the cells the on-screen labels belong
    /// to rather than by counting frames.
    @Test func theBoardShowsTheGridAndNotTheTakeParkedUnderIt() async throws {
        try await GridOutputProbe.withGridAndBoard { controller, model, boards, _ in
            let board: FakePlayoutOutput = try #require(boards.latest)
            #expect(controller.playbackTap.displayFrameHandler == nil,
                    "the parked take is still feeding the hardware output")
            #expect(controller.mirrors.syncGrid != nil)

            GridOutputProbe.deliver(model, tile: 1, code: 0xC0)
            GridOutputProbe.deliver(model, tile: 0, code: 0x40)
            #expect(await ControllerWait.untilWritten {
                !board.displayed.isEmpty
            }, "nothing reached the board while a comparison was up")

            let shown: CVPixelBuffer = try #require(board.displayed.last)
            // The feeder rebuilds anything that is not the output's own raster,
            // so read the picture by FRACTION of the frame rather than by pixel.
            let width = CVPixelBufferGetWidth(shown)
            let height = CVPixelBufferGetHeight(shown)
            let left = GridOutputProbe.red(of: shown, atX: width / 4, y: height / 2)
            let right = GridOutputProbe.red(of: shown, atX: width * 3 / 4, y: height / 2)
            #expect(abs(left - 0x40) <= 12,
                    "the left cell read \(left), not take one")
            #expect(abs(right - 0xC0) <= 12,
                    "the right cell read \(right), not take two")
        }
    }

    /// One compose serves every transport, however many there are.
    ///
    /// The same rule the live-picture pool keeps: the composition is a property
    /// of the PICTURE, not of who is watching it, so a second consumer costs a
    /// delivery and never a second pass. Counted at the board with a settle
    /// between frames, because `PlayoutFeeder` coalesces latest-wins and a burst
    /// would otherwise arrive as one.
    @Test func asecondTransportCostsNoSecondCompose() async throws {
        try await GridOutputProbe.withGridAndBoard { controller, model, boards, _ in
            let board: FakePlayoutOutput = try #require(boards.latest)
            let built = boards.all.count
            GridOutputProbe.deliver(model, tile: 1, code: 0x80)
            for step: Int in 0..<3 {
                GridOutputProbe.deliver(model, tile: 0, code: UInt8(0x30 + step * 0x10))
                #expect(await ControllerWait.untilWritten {
                    board.displayed.count > step
                }, "frame \(step) never reached the board")
                controller.mirrors.playout?.settle()
            }
            let alone: Int = board.displayed.count

            // A second transport on the same picture.
            controller.settings.ndi.enabled = true
            try #require(controller.mirrors.ndi != nil, "NDI did not come up")
            for step: Int in 0..<3 {
                GridOutputProbe.deliver(model, tile: 0, code: UInt8(0x70 + step * 0x10))
                #expect(await ControllerWait.untilWritten {
                    board.displayed.count > alone + step
                }, "frame \(step) never reached the board with NDI up")
                controller.mirrors.playout?.settle()
            }
            #expect(board.displayed.count == alone + 3,
                    "three clock frames produced \(board.displayed.count - alone) composes with two transports")
            #expect(boards.all.count == built,
                    "the output was rebuilt mid-count; the total is not a count of composes")
        }
    }

    // MARK: - what it costs when nobody is comparing

    /// Nobody comparing costs nothing: there is no composer and no picture, and
    /// the mirror slot is the single player's the way it always was.
    @Test func noComparisonMeansNoComposerAtAll() async throws {
        try await ControllerHarness.run { controller, root in
            MediaFixtures.silence(controller)
            let takes = try GridFixture.seedTakes(controller, in: root, count: 2)
            controller.viewerMode = .playback
            controller.playbackURL = takes[0].url
            #expect(controller.syncPlay == nil)
            #expect(controller.mirrors.syncGrid == nil)
            #expect(controller.mirrors.syncGridComposer == nil)
        }
    }

    /// **A comparison ON SCREEN and nowhere else costs nothing either**, and
    /// that is the half worth asserting: the tiles are already running for the
    /// operator's own layers, so the temptation is to compose because the frames
    /// are there. Nothing is watching, so nothing is composed — no GPU pass, and
    /// not even a `dispatch_async` per tile per frame, because the tile's slot
    /// is empty.
    @Test func aComparisonNobodyIsMirroringComposesNothing() async throws {
        try await GridOutputProbe.withGridAndBoard(board: false) { controller, model, _, _ in
            #expect(controller.mirrors.playout == nil)
            #expect(controller.mirrors.syncGridComposer == nil,
                    "a composer exists with nothing watching the grid")
            #expect(controller.mirrors.syncGrid == nil)
            for tile in model.tiles {
                #expect(tile.tap.displayFrameHandler == nil,
                        "a tile is paying a hop per frame for nobody")
            }
        }
    }

    /// …and the composer appears and disappears with the mirror rather than
    /// with the comparison. The switch is thrown in the middle of a session,
    /// which is what an operator does when the director walks up.
    @Test func theComposerFollowsTheMirrorAndNotTheComparison() async throws {
        try await GridOutputProbe.withGridAndBoard(board: false) { controller, model, _, _ in
            #expect(controller.mirrors.syncGridComposer == nil)

            controller.settings.ndi.enabled = true
            #expect(controller.mirrors.syncGridComposer != nil,
                    "a transport came up and the grid was still not composed")
            #expect(model.tiles.allSatisfy { $0.tap.displayFrameHandler != nil },
                    "a tile is not feeding the composed picture")

            controller.settings.ndi.enabled = false
            #expect(controller.mirrors.syncGridComposer == nil,
                    "the last transport went and the compose stayed")
            #expect(model.tiles.allSatisfy { $0.tap.displayFrameHandler == nil },
                    "a tile is still hopping to a composer nobody reads")
        }
    }

    // MARK: - what a tile pays

    /// **What a comparison costs the tap that draws it**, across the four
    /// configurations the choice has: no comparison, a comparison on screen
    /// only, one transport, two.
    ///
    /// Opt-in like the rest of this project's timings —
    ///
    ///     TAKESHOT_BENCH=1 scripts/test.sh --filter ControllerGridOutput
    ///
    /// — and nothing here asserts on a clock. What it measures is the ONLY
    /// thing a tile's own queue pays: the call into the display slot, which is
    /// an `offer` that hops and returns. The compose itself is on
    /// `com.takeshot.multiview.compose` and is measured where it happens
    /// (`MultiviewComposerTests.theComposeCostPerFrame`); the H.264 encodes, the
    /// board submit and NDI's own compression are each on a queue of their own
    /// downstream of that, exactly as they are for a live signal.
    ///
    /// The first two rows are zero by construction rather than by measurement —
    /// the slot is nil, which the assertions above pin — so they are printed as
    /// the nil test they are.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TAKESHOT_BENCH"] != nil))
    func whatATileFramePaysInEachConfiguration() async throws {
        try await GridOutputProbe.withGridAndBoard(tiles: 4) { controller, model, _, _ in
            let frame = MediaFixtures.pixelBuffer(level: 0x80, width: 1920,
                                                  height: 1080)
            let live = LiveFrame(decorated: frame, clean: frame)

            @MainActor func time(_ label: String) {
                let tap = model.tiles[1].tap
                guard tap.displayFrameHandler != nil else {
                    print("GRIDBENCH \(label): slot empty — nothing is called")
                    return
                }
                for _ in 0..<200 { tap.displayFrameHandler?(live) }
                var samples: [Double] = []
                for _ in 0..<2000 {
                    let start = DispatchTime.now().uptimeNanoseconds
                    tap.displayFrameHandler?(live)
                    samples.append(
                        Double(DispatchTime.now().uptimeNanoseconds - start)
                            / 1000)
                }
                samples.sort()
                print(String(format: "GRIDBENCH %@: min %.3f µs  median %.3f µs",
                             label, samples[0], samples[samples.count / 2]))
            }

            // one transport (the board), then two
            time("grid to one transport")
            controller.settings.ndi.enabled = true
            time("grid to two transports")
            // …and the two that cost nothing at all
            controller.settings.ndi.enabled = false
            controller.settings.capture.monitorDeviceID = nil
            time("grid on screen only")
            controller.endSyncPlay()
            print("GRIDBENCH no comparison: composer=\(controller.mirrors.syncGridComposer != nil)")
        }
    }
}
