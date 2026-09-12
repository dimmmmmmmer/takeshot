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

    /// **A window fits the frame and does not reframe it.**
    ///
    /// The mirror image of the first test, and the half that would otherwise
    /// go unnoticed: the geometry moved to the stage, so a layer that still
    /// applied it would flip an already-flipped picture back and leave the
    /// operator's own window the one surface showing something different from
    /// every other. Rendered and read rather than reasoned about — this is a
    /// claim about pixels.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil,
                   "no Metal device on this machine"))
    func aSurfaceFitsTheFrameAndDoesNotReframeIt() throws {
        let layer = MetalPreviewLayer()
        layer.setAssist(SizingProbe.flipped())
        let source = SizingProbe.sided()
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
