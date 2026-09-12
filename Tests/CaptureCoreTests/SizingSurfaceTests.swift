import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Metal
import Testing

@testable import CaptureCore

/// **A surface adds a fit and nothing else** — the other half of
/// `SizingReachTests`.
///
/// The nine sizing controls are applied in the shared display stage, into the
/// signal's own raster, so that every consumer of a frame carries the
/// operator's reframe. What is left to a window is putting that raster
/// somewhere, and what is left to the mouse is finding its way back through
/// both. Those are the claims here: the layer must not reframe an
/// already-framed picture, and a pick must land on the pixel under the pointer
/// through a flip, a rotation and the window's own fit.
struct SizingSurfaceTests {
    // MARK: - and a surface adds nothing to it

    /// **A window fits the frame and does nothing else to it.**
    ///
    /// The mirror image of the first test, and the half that would otherwise
    /// go unnoticed: the geometry moved to the stage, so a surface that
    /// reframed as well would flip an already-flipped picture back and leave
    /// the operator's own window the one showing something different from
    /// every other.
    ///
    /// The layer can no longer be TOLD a geometry at all — it stopped holding
    /// a `ViewAssist` when the last reader of one went away — so what is left
    /// to get wrong is the placement itself, and that is what is pinned here:
    /// the extent is a plain aspect-fit of the source (a zoom, a rotation, a
    /// desqueeze or a height would each move it), and the picture inside it is
    /// the one that went in rather than its mirror.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil,
                   "no Metal device on this machine"))
    func aSurfaceFitsTheFrameAndDoesNotReframeIt() throws {
        let layer = MetalPreviewLayer()
        let source = SizingProbe.sided()          // 64x32, dark left, bright right
        let raster = CGSize(width: 64, height: 32)
        for drawable in [CGSize(width: 128, height: 64),   // the same aspect
                         CGSize(width: 128, height: 128),  // taller: width-limited
                         CGSize(width: 256, height: 64)] { // wider: height-limited
            let placed = try #require(layer.placedImage(from: source,
                                                        in: drawable))
            let fit = min(drawable.width / raster.width,
                          drawable.height / raster.height)
            #expect(abs(placed.extent.width - raster.width * fit) <= 1
                && abs(placed.extent.height - raster.height * fit) <= 1,
                    "\(drawable): placed \(placed.extent), fit is \(fit)")
        }

        // …and at the one raster where a fraction of the drawable IS a
        // fraction of the picture, the halves are still where the camera put
        // them.
        let placed = try #require(layer.placedImage(
            from: source, in: CGSize(width: 128, height: 64)))
        let out = TestMedia.pixelBuffer(width: 128, height: 64)
        let context = CIContext(options: [.cacheIntermediates: false])
        let destination = CIRenderDestination(pixelBuffer: out)
        destination.colorSpace = nil
        let task = try context.startTask(toRender: placed, to: destination)
        try task.waitUntilCompleted()

        #expect(PreviewProbe.level(of: out, atFractionX: 0.1) < 100,
                "the surface flipped a frame the stage had already framed")
        #expect(PreviewProbe.level(of: out, atFractionX: 0.9) > 150,
                "the surface flipped a frame the stage had already framed")
    }

    /// **A stale pan does not slide the picture off centre.**
    ///
    /// Unmagnified there is nowhere to pan to — `panLimit` says so and every
    /// mutator clamps to it — but the fields are stored settings and a restore
    /// writes them straight in, so a session saved punched-in and reopened at
    /// 1x arrives carrying a pan nothing has clamped. The two transforms read
    /// `effectivePan` rather than the field for that reason, and this is the
    /// half that moves PIXELS: the overlays' twin is
    /// `AssistGeometryTests.panIsIgnoredWhileNotPunchedIn`.
    @Test func aStalePanDoesNotSlideThePicture() throws {
        var stale = PictureSizing()
        stale.zoom = 1
        stale.panX = 0.4
        let source = CIImage(cvPixelBuffer: SizingProbe.sided(width: 64, height: 32),
                             options: [.colorSpace: NSNull()])
        let frame = CGRect(x: 0, y: 0, width: 64, height: 32)
        let out = TestMedia.pixelBuffer(width: 64, height: 32)
        let context = CIContext(options: [.cacheIntermediates: false])
        let destination = CIRenderDestination(pixelBuffer: out)
        destination.colorSpace = nil
        let task = try context.startTask(
            toRender: stale.applied(to: source, in: frame,
                                    letterbox: CIColor(red: 0, green: 0, blue: 0)),
            to: destination)
        try task.waitUntilCompleted()
        // the halves are still where the camera put them: the boundary is the
        // middle of the frame, not four tenths of a frame to one side of it
        #expect(PreviewProbe.level(of: out, atFractionX: 0.45) < 100,
                "a pan at 1x moved the picture")
        #expect(PreviewProbe.level(of: out, atFractionX: 0.55) > 150,
                "a pan at 1x moved the picture")
    }

    /// The frame the surface is holding, read the way the renderer writes it.
    /// `nonisolated` and not inline: `NSLock` is unavailable from an async
    /// context, and the wait below is one.
    private nonisolated static func held(by layer: MetalPreviewLayer)
        -> CVPixelBuffer? {
        layer.renderLock.lock()
        defer { layer.renderLock.unlock() }
        return layer.lastBuffer
    }

    /// **One flip reaches the window, not two.**
    ///
    /// The end-to-end version of the claim above, and the one that survives
    /// the layer having no assist to be armed with: drive the whole path —
    /// the stage applies the reframe, the sink is handed the result, the
    /// surface places it — and read the picture at both ends. A surface that
    /// reframed as well would flip an already-flipped frame back, and the
    /// operator's own window would be the one place on the unit showing
    /// something different from every other.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil,
                   "no Metal device on this machine"))
    func oneFlipReachesTheWindowAndNotTwo() async throws {
        let pipeline = PreviewProbe.makePipeline()
        pipeline.setViewAssist(SizingProbe.flipped())
        let layer = MetalPreviewLayer()
        layer.setDrawableSize(CGSize(width: 128, height: 64))
        pipeline.addDisplaySink(layer)
        defer { pipeline.removeDisplaySink(layer) }

        let source = SizingProbe.sided()
        var index = 0
        await TestWait.untilWritten {
            layer.redrawQueue.sync {}
            if let held = Self.held(by: layer),
               PreviewProbe.level(of: held, atFractionX: 0.1) > 150 {
                return true
            }
            index += 1
            PreviewProbe.push(pipeline, source, frame: index)
            return false
        }

        let held = try #require(Self.held(by: layer),
                                "no frame reached the surface")
        // the stage flipped it once…
        #expect(PreviewProbe.level(of: held, atFractionX: 0.1) > 150,
                "the reframe never reached the surface")

        // …and placing it in a window flips it no further
        let placed = try #require(layer.placedImage(
            from: held, in: CGSize(width: 128, height: 64)))
        let out = TestMedia.pixelBuffer(width: 128, height: 64)
        let context = CIContext(options: [.cacheIntermediates: false])
        let destination = CIRenderDestination(pixelBuffer: out)
        destination.colorSpace = nil
        let task = try context.startTask(toRender: placed, to: destination)
        try task.waitUntilCompleted()
        #expect(PreviewProbe.level(of: out, atFractionX: 0.1) > 150,
                "the window flipped an already-flipped picture back")
        #expect(PreviewProbe.level(of: out, atFractionX: 0.9) < 100)
    }

    // MARK: - and the mouse follows it

    /// **A pick lands on the pixel the operator is pointing at**, through the
    /// reframe and through the window's own fit.
    ///
    /// The eyedropper, the chroma pick and the taught-REC box all invert the
    /// same transform, and this is the case that used to be wrong by
    /// construction: the mapping ignored the flips and the rotation entirely,
    /// so on a flipped picture every pick landed on the mirror of the pixel
    /// under the pointer.
    @Test func aPickLandsWhereThePointerIsThroughAFlip() throws {
        let raster = CGSize(width: 1920, height: 1080)
        let viewport = CGSize(width: 960, height: 540)
        let plain = ViewAssist()
        let mirror = SizingProbe.flipped()
        // a quarter of the way in from the left of the window
        let point = CGPoint(x: 240, y: 270)
        let straight = try #require(plain.imageFraction(of: point,
                                                        sourceSize: raster,
                                                        in: viewport))
        let through = try #require(mirror.imageFraction(of: point,
                                                        sourceSize: raster,
                                                        in: viewport))
        #expect(abs(straight.x - 0.25) < 0.001)
        #expect(abs(through.x - 0.75) < 0.001,
                "a pick through a flip landed at \(through.x)")
        #expect(abs(through.y - straight.y) < 0.001,
                "a horizontal flip moved the pick vertically")
    }

    /// …and a point on the letterbox is refused rather than clamped onto the
    /// nearest pixel. A shrunk picture leaves bars INSIDE the raster now, and
    /// there is no pixel out there to answer for.
    @Test func aPickOnTheBarsOfAShrunkPictureIsRefused() throws {
        let raster = CGSize(width: 1920, height: 1080)
        let viewport = CGSize(width: 1920, height: 1080)
        var shrunk = ViewAssist()
        shrunk.setPunchIn(1)
        shrunk.height = 0.5
        // the picture is half-height and centred, so the top of the frame is bar
        #expect(shrunk.imageFraction(of: CGPoint(x: 960, y: 20),
                                     sourceSize: raster, in: viewport) == nil)
        #expect(shrunk.imageFraction(of: CGPoint(x: 960, y: 540),
                                     sourceSize: raster, in: viewport) != nil)
    }
}
