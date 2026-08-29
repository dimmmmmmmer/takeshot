import CaptureCore
@preconcurrency import CoreImage
import CoreVideo
import Foundation
import Testing

@testable import TakeShotKit

/// **A tile whose board is not feeding says so** — what it costs, and that it
/// reaches the picture over the right cell.
///
/// Its own suite rather than more of `MultiviewIdentityCostTests`, which is at
/// the type-length ceiling, and it is a question of its own anyway: that one is
/// about a badge that changes when an operator acts, this one is about a badge
/// that changes when a CABLE moves — which can be twice a second, and is the
/// only reason the cost of it is interesting at all.
///
/// Everything here is one of the two portable kinds this project allows for
/// drawn things: **counted work** (`TileBadge.rasterCount` is the same number
/// on every machine) and **the plate's own code** (an alpha composite of one
/// constant colour is arithmetic, not typography). Nothing reads a glyph — see
/// `MultiviewIdentityTests` for why, and for what that leaves uncovered,
/// including the one thing that matters most here: nothing can tell that the
/// legend is in a language its reader has.
@Suite struct MultiviewNoSignalTests {
    // MARK: - what it costs

    /// **A grid of dark tiles costs ONE bitmap, and a board flapping costs
    /// none.**
    ///
    /// Both halves are the content key doing its job rather than a special
    /// case, which is why they are worth pinning as numbers. Every cell of a
    /// given grid is the same size, so four dark tiles ask for the same words
    /// at the same type size in the same room — one key. And the key carries
    /// what is DRAWN, not the state that decides whether to draw it, so a board
    /// on a bad cable toggling twice a second alternates between compositing
    /// one cached bitmap and compositing nothing. Neither rasterizes.
    ///
    /// That second half is the whole answer to "a badge that changes state
    /// twice a second must not evict the nameplates": it does not change the
    /// TABLE at all.
    @Test func aDarkGridCostsOneLegendAndAFlappingBoardCostsNone() {
        TileBadge.resetForTesting()
        let canvas = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        for camera: Int in 0..<4 {
            let cell = MultiviewComposer.cell(camera: camera, cameras: 4,
                                              in: canvas)
            let metrics = TileTypeMetrics(tileHeight: cell.height)
            _ = TileBadge.noSignal(metrics: metrics,
                                   maximumWidth: metrics.maximumWidth(in: cell))
        }
        #expect(TileBadge.rasterCount == 1,
                "four dark tiles drew \(TileBadge.rasterCount) legends")

        let cell = MultiviewComposer.cell(camera: 0, cameras: 4, in: canvas)
        let metrics = TileTypeMetrics(tileHeight: cell.height)
        let room = metrics.maximumWidth(in: cell)
        for _ in 0..<100 {
            _ = TileBadge.noSignal(metrics: metrics, maximumWidth: room)
        }
        #expect(TileBadge.rasterCount == 1,
                "100 flaps drew \(TileBadge.rasterCount) legends")
    }

    /// **The legend does not push a nameplate out of the cache**, which is the
    /// one way this badge could have cost something real.
    ///
    /// The LRU is bounded so a rolling clock cannot leak, and the bound is
    /// sized so that the entries touched on EVERY compose survive the clocks
    /// churning past them. Adding a fifth such entry narrows that headroom, so
    /// the claim is measured here rather than argued: forty frames of a
    /// four-up, every tile dark and every tile's clock running its own
    /// timecode, is 160 distinct clock keys through a table of 24.
    ///
    /// The total is asserted as well as the survival, and it is the stronger
    /// half: a nameplate evicted at frame 20 and redrawn at frame 21 would
    /// still be a cache HIT at the end, and only the count would show it.
    @Test func aRollingClockOverADarkGridNeverEvictsANameplate() {
        TileBadge.resetForTesting()
        let canvas = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let cell = MultiviewComposer.cell(camera: 0, cameras: 4, in: canvas)
        let metrics = TileTypeMetrics(tileHeight: cell.height)
        let room = metrics.maximumWidth(in: cell)
        let names: [String] = ["A CAM", "B CAM", "C CAM", "D CAM"]
        let ticks = 40

        // The order inside a frame is the composer's own: nameplate, clock,
        // legend, tile by tile — see `MultiviewComposer.marked`.
        for tick: Int in 0..<ticks {
            for (index, name) in names.enumerated() {
                _ = TileBadge.nameplate(
                    for: .camera(label: name, recording: false,
                                 signalPresent: false),
                    metrics: metrics, maximumWidth: room)
                // each board runs its own timecode, which is what a live
                // multicam grid does and the worst case for this table
                _ = TileBadge.clock(
                    text: String(format: "10:0%d:00:%02d", index, tick),
                    metrics: metrics, maximumWidth: room)
                _ = TileBadge.noSignal(metrics: metrics, maximumWidth: room)
            }
        }
        let drawn = TileBadge.rasterCount
        #expect(drawn == names.count + 1 + names.count * ticks,
                """
                \(ticks) frames of a dark four-up drew \(drawn) bitmaps, \
                against the \(names.count + 1 + names.count * ticks) that are \
                four nameplates, one legend and one clock per tile per tick — \
                anything more is an entry that had to be drawn twice
                """)

        // …and every one of the five that must survive is still a hit.
        for name in names {
            _ = TileBadge.nameplate(
                for: .camera(label: name, recording: false,
                             signalPresent: false),
                metrics: metrics, maximumWidth: room)
        }
        _ = TileBadge.noSignal(metrics: metrics, maximumWidth: room)
        #expect(TileBadge.rasterCount == drawn,
                """
                \(names.count * ticks) clock ticks evicted \
                \(TileBadge.rasterCount - drawn) of the five entries a dark \
                grid touches on every compose
                """)
    }

    // MARK: - through the composer

    /// **A tile with no signal says so, in the middle of ITS OWN cell and of no
    /// other.**
    ///
    /// The whole feature, read out of the composed picture. One board of four
    /// is not feeding, so exactly one cell's middle is darkened by a plate and
    /// the other three arrive at their own code exactly — which is the same
    /// pair of assertions `theIdentityLeavesTheTileCodesAlone` makes about the
    /// corners, for the reason it states: on its own each half is satisfied by
    /// the failure the other one catches. A legend drawn over every tile would
    /// pass "the dark tile says so"; a legend drawn over none would pass "the
    /// feeding tiles are untouched".
    ///
    /// Four tiles so each 16:9 source fills its own 16:9 cell exactly — with
    /// two, the cells are 8:9 and the middle of a tile is picture either way,
    /// but the letterbox reasoning at the other test applies to the corners and
    /// keeping one fixture shape keeps the two comparable.
    ///
    /// The plate's code is arithmetic and not typography — 0x40 under 55 %
    /// black is about 0x1D on any machine — which is why this may be read where
    /// a glyph may not.
    @Test func aTileWithNoSignalSaysSoOverItsOwnCellAlone() async throws {
        TileBadge.resetForTesting()
        let code: UInt8 = 0x40
        let dark = 2
        let canvas = CGRect(x: 0, y: 0, width: 640, height: 360)
        let composed = ComposedFrames()
        let composer = MultiviewComposer { buffer, rate in
            composed.record(buffer, rate: rate)
        }
        composer.setCameraCount(4)
        for camera: Int in 0..<4 {
            composer.setIdentity(.camera(label: "CAM \(camera)",
                                         recording: false,
                                         signalPresent: camera != dark),
                                 camera: camera)
        }
        for camera: Int in 1..<4 {
            composer.offer(try ComposerProbe.buffer(code: code, width: 640,
                                                    height: 360),
                           camera: camera, framesPerSecond: 0)
        }
        composer.offer(try ComposerProbe.buffer(code: code, width: 640,
                                                height: 360),
                       camera: 0, framesPerSecond: 25)
        #expect(await ControllerWait.untilWritten { composed.count > 0 })
        let out: CVPixelBuffer = try #require(composed.latest)

        for camera: Int in 0..<4 {
            try check(out, camera: camera, code: Int(code),
                      expectingLegend: camera == dark, in: canvas)
        }
        composer.stop()
    }

    /// The middle of one tile: darkened by the legend's plate, or the picture's
    /// own code exactly.
    ///
    /// Sampled one inset in from the plate's LEFT edge — inside it, and short
    /// of where the words begin, so no glyph is what is read. That is the same
    /// point `MultiviewIdentityCostTests` samples the two captions at and for
    /// the same reason: the plate's own centre is exactly where the TEXT is,
    /// and reading it there measured 228 against a picture of 64 on the first
    /// draft of this test.
    private func check(_ out: CVPixelBuffer, camera: Int, code: Int,
                       expectingLegend: Bool, in canvas: CGRect) throws {
        let cell = MultiviewComposer.cell(camera: camera, cameras: 4,
                                          in: canvas)
        let metrics = TileTypeMetrics(tileHeight: cell.height)
        let plate: CIImage = try #require(TileBadge.noSignal(
            metrics: metrics, maximumWidth: metrics.maximumWidth(in: cell)))
        let origin = metrics.noticeOrigin(in: cell, size: plate.extent.size)
        // the sampler reads top row first; the layout is bottom-left origin
        let level: Int = ComposerProbe.level(
            of: out, atX: Int(origin.x + metrics.textInset / 2),
            y: Int(canvas.height - 1 - (origin.y + metrics.plateHeight / 2)))
        if expectingLegend {
            #expect(level < code,
                    """
                    camera \(camera) read \(level) in the middle — the board \
                    is not feeding and the tile does not say so
                    """)
        } else {
            #expect(level == code,
                    """
                    camera \(camera) read \(level) in the middle — a feeding \
                    tile was written over
                    """)
        }
    }
}
