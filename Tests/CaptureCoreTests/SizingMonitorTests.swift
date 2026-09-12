import CoreImage
import CoreVideo
import Foundation
import Testing

@testable import CaptureCore

/// **The crew's picture carries the framing and none of the tools** (owner:
/// "на телефоне пусть тоже будет кадрирование").
///
/// The phone camera grid and the browser's clean stream take
/// `LivePicture.clean`, and everything the operator switched on for themselves
/// is wrong on those: false colour tells a gaffer the scene is on fire, a
/// frameline matte reads as the actual frame, a pinned-reference wipe puts half
/// of an hour-old frame in a tile labelled A-cam. The REFRAME is not one of
/// those — an anamorphic feed shown squeezed on a room of phones is simply
/// wrong, and a flip is the way the camera is hung.
///
/// Where the line falls inside the reframe is the operator's own answer: the
/// settled framing goes, the magnification and its pan stay behind ("всё кроме
/// зума и пана"). That is the split the app already makes when it decides which
/// of the nine survive a relaunch — "a magnification is a moment in a shot, not
/// a way of working".
struct SizingMonitorTests {
    private static func assist(_ change: (inout ViewAssist) -> Void) -> ViewAssist {
        var value = ViewAssist()
        change(&value)
        return value
    }

    /// The last frame the grid was handed, having pushed until one arrives.
    private func gridTile(_ pipeline: CapturePipeline,
                          _ source: CVPixelBuffer) async throws -> CVPixelBuffer {
        let grid = PreviewCollector()
        pipeline.setOnMonitorFrame { grid.record($0[.clean]) }
        defer { pipeline.setOnMonitorFrame(nil) }
        var index = 0
        await TestWait.untilWritten {
            guard grid.count == 0 else { return true }
            index += 1
            PreviewProbe.push(pipeline, source, frame: index)
            return false
        }
        return try #require(grid.last, "nothing reached the camera grid")
    }

    // MARK: - the value

    /// The split itself, as arithmetic: the settled framing keeps the seven
    /// that persist and drops the two that do not.
    @Test func theSettledFramingIsEverythingButTheMagnification() {
        var full = PictureSizing()
        full.width = 2
        full.height = 1.5
        full.rotation = 12
        full.pitch = -4
        full.yaw = 7
        full.flipH = true
        full.flipV = true
        full.zoom = 4
        full.panX = 0.2
        full.panY = -0.1
        let settled = full.settled
        #expect(settled.width == 2 && settled.height == 1.5)
        #expect(settled.rotation == 12 && settled.pitch == -4 && settled.yaw == 7)
        #expect(settled.flipH && settled.flipV)
        #expect(settled.zoom == 1 && settled.panX == 0 && settled.panY == 0,
                "the magnification followed the operator out of the room")
        // **And therefore it cannot CROP** — the formal answer to the sharpest
        // rule against putting any geometry on a tile: "a tile cropped to its
        // cell would hide the edges of a frame somebody is using to judge what
        // is in shot, which is the one thing a monitoring surface must not do"
        // (`MultiviewComposer`). Everything before the zoom is aspect-fitted
        // into the frame, so with the zoom at 1 nothing can leave it.
        #expect(!settled.isCropping,
                "the crew's picture can lose an edge of the frame")
        #expect(full.isCropping, "the fixture crops nothing, so this proves nothing")
        // …and a reframe that is only a punch-in settles to nothing at all,
        // which is what keeps the crew's picture free in the common case.
        var punched = PictureSizing()
        punched.zoom = 3
        punched.panX = 0.1
        #expect(punched.settled.isIdentity)
        #expect(PictureSizing().settled.isIdentity)
    }

    // MARK: - the picture

    /// A flip reaches the phone.
    @Test func theSettledFramingReachesTheCameraGrid() async throws {
        let pipeline = PreviewProbe.makePipeline()
        pipeline.setViewAssist(Self.assist { $0.flipH = true })
        let source = SizingProbe.sided()
        let tile = try await gridTile(pipeline, source)

        #expect(tile !== source, "the grid was handed the unframed buffer")
        #expect(PreviewProbe.level(of: tile, atFractionX: 0.1) > 150,
                "the flip never reached the phone")
        #expect(PreviewProbe.level(of: tile, atFractionX: 0.9) < 100)
    }

    /// …and a punch-in does not. The operator checks focus at 4x; the crew
    /// keeps the shot.
    @Test func theMagnificationStaysWithTheOperator() async throws {
        let pipeline = PreviewProbe.makePipeline()
        pipeline.setViewAssist(Self.assist {
            $0.setPunchIn(4)
            $0.panX = 0.1
        })
        let source = SizingProbe.sided()
        let tile = try await gridTile(pipeline, source)

        // Nothing to apply, so nothing is spent and nothing is copied: the
        // grid is handed the very buffer the frame path produced.
        #expect(tile === source,
                "a punch-in reached the phone, or cost it a render anyway")
    }

    /// **And a mirror that takes only the decorated picture pays nothing.**
    ///
    /// The commonest rig on set is a hardware monitor out and no phones in the
    /// room: the playout, NDI and SRT can only ever take `.decorated`, and a
    /// full-raster CoreImage pass per frame for a buffer nobody reads would be
    /// a third pass on a queue that already runs the keyer and the aids.
    @Test func aMirrorThatTakesOnlyTheDecoratedPictureCostsNoFramingPass() async throws {
        let pipeline = PreviewProbe.makePipeline()
        pipeline.setViewAssist(Self.assist { $0.flipH = true })
        let seen = PreviewCollector()
        // the mirrors slot, with no monitor handler and no demand declared
        pipeline.setOnDisplayFrame { seen.record($0[.clean]) }
        defer { pipeline.setOnDisplayFrame(nil) }
        let source = SizingProbe.sided()
        var index = 0
        await TestWait.untilWritten {
            guard seen.count == 0 else { return true }
            index += 1
            PreviewProbe.push(pipeline, source, frame: index)
            return false
        }
        #expect(!pipeline.mirrorsTakeClean, "the demand was declared by nobody")
        #expect(seen.last === source,
                "a framing pass was spent for a picture nobody takes")

        // …and declaring the demand turns it on, with no other change
        pipeline.setMirrorsTakeCleanPicture(true)
        let before = seen.count
        await TestWait.untilWritten {
            guard seen.count == before else { return true }
            index += 1
            PreviewProbe.push(pipeline, source, frame: index)
            return false
        }
        #expect(seen.last !== source, "the declared demand changed nothing")
        #expect(seen.last.map { PreviewProbe.level(of: $0, atFractionX: 0.1) }
            ?? 0 > 150, "the flip never reached the declared consumer")
    }

    /// **It reaches the phone and the MEASUREMENT path nowhere.**
    ///
    /// The clean buffer is the same object the compare provider pulls and, on
    /// an 8-bit source with no preview LUT, the same one the scopes read and
    /// the writer is handed. The reframe is rendered into a buffer of its own,
    /// so every one of those still holds what the camera sent.
    @Test func theFramingNeverReachesTheMeasurementPath() async throws {
        let pipeline = PreviewProbe.makePipeline()
        pipeline.setViewAssist(Self.assist { $0.flipH = true })
        let source = SizingProbe.sided()
        let tile = try await gridTile(pipeline, source)

        #expect(PreviewProbe.level(of: tile, atFractionX: 0.1) > 150,
                "the flip never reached the phone, so this proves nothing")
        let measured = try #require(pipeline.currentPreviewBuffer())
        #expect(measured === source,
                "the reframe reached the compare provider's own buffer")
        #expect(PreviewProbe.level(of: measured, atFractionX: 0.1) < 100,
                "the measured frame came back flipped")
    }

    /// **A redraw re-publishes the pair it published**, not the screen buffer
    /// twice.
    ///
    /// Moving any slider re-pushes the last frame through the display stage,
    /// and that door used to hand the phones the SCREEN buffer as their clean
    /// picture — which carries the pinned-reference wipe. Half of an hour-old
    /// frame in a tile labelled A-cam, every time a finger moved.
    @Test func aRedrawDoesNotPutTheOperatorsWipeOnThePhones() async throws {
        let pipeline = PreviewProbe.makePipeline()
        let source = PreviewProbe.frame(0x20)
        pipeline.setPreviewReference(buffer: PreviewProbe.frame(0xE0))
        pipeline.setPreviewCompare(.wipe(axis: .vertical, position: 0.5))
        let grid = PreviewCollector()
        pipeline.setOnMonitorFrame { grid.record($0[.clean]) }
        defer { pipeline.setOnMonitorFrame(nil) }
        var index = 0
        await TestWait.untilWritten {
            guard grid.count == 0 else { return true }
            index += 1
            PreviewProbe.push(pipeline, source, frame: index)
            return false
        }

        // …now a slider moves, with no new frame behind it
        let seen = grid.count
        pipeline.setViewAssist(Self.assist { $0.zebraOn = true })
        await TestWait.untilWritten { grid.count > seen }
        pipeline.settleDisplay()

        let tile = try #require(grid.last, "the redraw published nothing")
        #expect(PreviewProbe.level(of: tile, atFractionX: 0.1) == 0x20,
                "the redraw put the operator's reference on the phone")
        #expect(PreviewProbe.level(of: tile, atFractionX: 0.9) == 0x20)
    }
}
