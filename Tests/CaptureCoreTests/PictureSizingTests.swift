import CoreGraphics
import Foundation
import Testing

@testable import CaptureCore

/// **The nine sizing controls, as arithmetic** — `PictureSizing`.
///
/// Every assertion here is about the affine half: where the picture lands,
/// what a control does to it, and whether the overlays can still invert it.
/// The pixels are the next suite over (`PictureSizingRenderTests`), and the
/// two are pinned to each other there.
@Suite struct PictureSizingTests {
    private let source = CGSize(width: 1920, height: 1080)
    private let viewport = CGSize(width: 960, height: 540)

    /// **An identity sizing places exactly where the aspect-fit did.**
    ///
    /// The first thing to be sure of: the whole feature is a generalisation of
    /// the fit that has always been there, so with nothing set it has to be
    /// that fit to the pixel — the framelines, the safe areas and the
    /// eyedropper are all laid out against it.
    @Test func anIdentitySizingPlacesExactlyAsTheFitDid() throws {
        let rect = try #require(PictureSizing().pictureRect(sourceSize: source,
                                                            in: viewport))
        let old = try #require(ViewAssist().placement(sourceSize: source,
                                                      in: viewport))
        #expect(abs(rect.minX - old.rect.minX) < 0.001)
        #expect(abs(rect.minY - old.rect.minY) < 0.001)
        #expect(abs(rect.width - old.rect.width) < 0.001)
        #expect(abs(rect.height - old.rect.height) < 0.001)
    }

    /// **Width and height are independent**, which is the whole of what
    /// `height` adds: the desqueeze was one axis by construction, and a
    /// colourist stretching only the vertical is doing something this app
    /// could not do at all.
    @Test func widthAndHeightScaleIndependently() throws {
        let square = CGSize(width: 100, height: 100)
        var sizing = PictureSizing()
        sizing.width = 2
        let wide = try #require(sizing.pictureRect(sourceSize: square,
                                                   in: viewport))
        #expect(abs(wide.width / wide.height - 2) < 0.001, """
            a width of 2 on a square source came out \(wide.width / wide.height):1
            """)
        sizing = PictureSizing()
        sizing.height = 2
        let tall = try #require(sizing.pictureRect(sourceSize: square,
                                                   in: viewport))
        #expect(abs(tall.height / tall.width - 2) < 0.001, """
            a height of 2 on a square source came out 1:\(tall.height / tall.width)
            """)
    }

    /// **Zoom goes below one**, which the punch-in it replaces could not: that
    /// one floored at 1 because it was a focus aid. A shrunk picture sits
    /// inside the frame with letterbox all round it.
    @Test func zoomBelowOneShrinksInsideTheFrame() throws {
        var sizing = PictureSizing()
        sizing.setZoom(0.5)
        #expect(sizing.zoom == 0.5, "the zoom was clamped back up to 1")
        let rect = try #require(sizing.pictureRect(sourceSize: source,
                                                   in: viewport))
        let full = try #require(PictureSizing().pictureRect(sourceSize: source,
                                                            in: viewport))
        #expect(abs(rect.width - full.width / 2) < 0.001)
        #expect(rect.minX > 0 && rect.maxX < viewport.width, """
            a half-size picture is not inside the frame: \(rect)
            """)
    }

    /// **The pan is clamped to what the zoom leaves off the frame**, and at
    /// zoom 1 that is nothing at all. A flat ±0.5 let the operator pan
    /// letterbox into the middle of the picture, which is the defect this
    /// limit was written for.
    @Test func panIsClampedToWhatTheZoomLeaves() {
        var sizing = PictureSizing()
        sizing.setZoom(2)
        sizing.panX = 5
        sizing.panY = -5
        sizing.clampPan()
        #expect(abs(sizing.panX - 0.25) < 1e-9, "panX clamped to \(sizing.panX)")
        #expect(abs(sizing.panY + 0.25) < 1e-9, "panY clamped to \(sizing.panY)")
        sizing.setZoom(1)
        #expect(sizing.panX == 0 && sizing.panY == 0, """
            zooming back out left the picture parked off-centre at \
            \(sizing.panX), \(sizing.panY)
            """)
    }

    /// **A flip is its own inverse** — about the SOURCE's centre, which is
    /// what makes that true whatever else is set. Flipping about the FRAME's
    /// centre would move a panned or zoomed picture as well as mirroring it.
    @Test func flippingTwiceIsTheSamePlacement() throws {
        var sizing = PictureSizing()
        sizing.setZoom(2)
        sizing.panX = 0.1
        sizing.rotation = 12
        let plain = try #require(sizing.pictureRect(sourceSize: source,
                                                    in: viewport))
        sizing.flipH = true
        sizing.flipH = false
        let back = try #require(sizing.pictureRect(sourceSize: source,
                                                   in: viewport))
        #expect(abs(plain.minX - back.minX) < 0.001)
        #expect(abs(plain.width - back.width) < 0.001)
    }

    /// **A rotation turns the PICTURE, not the frame.** Ninety degrees of a
    /// 16:9 source into a 16:9 frame is a tall picture in a wide window —
    /// pillarboxed, not cropped, because the fit happens after the turn.
    @Test func rotationTurnsThePictureAndNotTheFrame() throws {
        var sizing = PictureSizing()
        sizing.rotation = 90
        let rect = try #require(sizing.pictureRect(sourceSize: source,
                                                   in: viewport))
        #expect(abs(rect.height - viewport.height) < 0.001, """
            the turned picture is \(rect.height) tall in a \(viewport.height) \
            frame — it should be fitted to the height
            """)
        #expect(rect.width < viewport.width - 1, """
            the turned picture is \(rect.width) wide in a \(viewport.width) \
            frame: nothing was pillarboxed
            """)
        #expect(abs(rect.width - viewport.height * source.height / source.width)
            < 0.001)
    }

    /// **Only pitch and yaw are non-affine**, and a non-affine sizing has no
    /// transform to hand out at all — every caller that inverts it has to
    /// refuse rather than fall back to the identity.
    @Test func onlyPitchAndYawAreNonAffine() {
        var sizing = PictureSizing()
        sizing.rotation = 30
        sizing.flipV = true
        sizing.width = 1.5
        sizing.setZoom(3)
        #expect(sizing.isAffine)
        #expect(sizing.transform(sourceSize: source, in: viewport) != nil)
        sizing.yaw = 5
        #expect(!sizing.isAffine)
        #expect(sizing.transform(sourceSize: source, in: viewport) == nil, """
            a yawed sizing handed out an affine transform — the eyedropper \
            would land on the wrong pixel and say nothing
            """)
        sizing.yaw = 0
        sizing.pitch = -5
        #expect(!sizing.isAffine)
        #expect(sizing.pictureRect(sourceSize: source, in: viewport) == nil)
    }

    /// **Cropping is reported only when picture is actually lost.** A flip, a
    /// rotation, a stretch and a shrink all keep every pixel the camera sent —
    /// they are fitted into the frame. Only a zoom above 1 pushes picture out
    /// of it, and only that may raise the record warning: a warning that cries
    /// wolf on a flip is a warning nobody reads.
    @Test func croppingIsReportedOnlyWhenPictureIsLost() {
        var sizing = PictureSizing()
        #expect(!sizing.isCropping)
        sizing.flipH = true
        sizing.rotation = 33
        sizing.width = 2
        sizing.height = 0.5
        sizing.setZoom(0.4)
        #expect(!sizing.isCropping, "a fitted sizing claimed to be cropping")
        sizing.setZoom(1.01)
        #expect(sizing.isCropping, "a zoom past 1 did not report the crop")
    }

    /// **The overlays' inverse holds for every affine sizing.** The eyedropper,
    /// the chroma pick and the taught-REC box all ask "what pixel is under this
    /// point"; rotation and flip come for free only if the inverse really is
    /// the inverse.
    @Test func theOverlayTransformInvertsForEveryAffineSizing() throws {
        var table: [PictureSizing] = [PictureSizing()]
        var rotated = PictureSizing()
        rotated.rotation = 17
        table.append(rotated)
        var flipped = PictureSizing()
        flipped.flipH = true
        flipped.flipV = true
        table.append(flipped)
        var zoomed = PictureSizing()
        zoomed.setZoom(3)
        zoomed.panX = 0.2
        zoomed.clampPan()
        table.append(zoomed)
        var stretched = PictureSizing()
        stretched.width = 1.33
        stretched.height = 0.8
        table.append(stretched)

        for sizing in table {
            let matrix = try #require(sizing.transform(sourceSize: source,
                                                       in: viewport))
            // a point ON the picture, stated in source pixels, taken to the
            // surface and asked for again
            let pixel = CGPoint(x: source.width * 0.3, y: source.height * 0.7)
            let onScreen = pixel.applying(matrix)
            let fraction = try #require(
                sizing.imageFraction(of: onScreen, sourceSize: source,
                                     in: viewport),
                "the inverse refused a point that is on the picture")
            #expect(abs(fraction.x - 0.3) < 0.001, """
                the inverse of \(sizing) put x at \(fraction.x), not 0.3
                """)
            #expect(abs(fraction.y - 0.7) < 0.001, """
                the inverse of \(sizing) put y at \(fraction.y), not 0.7
                """)
        }
    }

    /// A point on the letterbox has no pixel to answer for, and says so.
    @Test func aPointOffThePictureHasNoAnswer() {
        var sizing = PictureSizing()
        sizing.setZoom(0.5)
        let corner = CGPoint(x: 2, y: 2)
        #expect(sizing.imageFraction(of: corner, sourceSize: source,
                                     in: viewport) == nil)
    }

    /// **Every surface shows the same framing.** A window adds a fit and
    /// nothing else.
    ///
    /// The nine controls are applied INTO THE SIGNAL'S RASTER, in the shared
    /// display stage, so the reframe is in the delivered frame and reaches the
    /// hardware playout, the multiview and the phone grid — the surfaces that
    /// are handed a pixel buffer and have no layer to do it for them. They
    /// used to be applied per surface, which meant the operator's own window
    /// was the only place the reframe existed at all.
    ///
    /// So the claim worth pinning is not a formula, it is that one: the
    /// picture's place inside the raster, as fractions of it, is the same
    /// whatever is looking. A viewport that changed the framing would be a
    /// director's monitor framed differently from the operator's window.
    @Test func everySurfaceShowsTheSameFraming() throws {
        let raw = CGSize(width: 1920, height: 1080)
        let viewports = [CGSize(width: 800, height: 500),
                         CGSize(width: 1920, height: 1080),
                         CGSize(width: 640, height: 640),
                         CGSize(width: 2400, height: 600)]
        for desqueeze in [1.0, 1.33, 2.0, 0.75] {
            for punchIn in [1.0, 2.0, 4.5] {
                for pan in [0.0, 0.1, -0.2] {
                    var assist = ViewAssist()
                    assist.desqueeze = desqueeze
                    assist.setPunchIn(punchIn)
                    assist.panX = pan
                    assist.panY = -pan
                    assist.clampPan()
                    let label = "desqueeze \(desqueeze) punch \(punchIn) pan \(pan)"
                    // what the STAGE draws, inside the signal's own raster
                    let drawn = try #require(
                        assist.sizing.pictureRect(sourceSize: raw, in: raw))
                    let wanted = CGRect(x: drawn.minX / raw.width,
                                        y: drawn.minY / raw.height,
                                        width: drawn.width / raw.width,
                                        height: drawn.height / raw.height)
                    for viewport in viewports {
                        let got = try #require(framing(assist, raw: raw,
                                                       in: viewport))
                        #expect(abs(got.minX - wanted.minX) < 0.000_1
                            && abs(got.minY - wanted.minY) < 0.000_1
                            && abs(got.width - wanted.width) < 0.000_1
                            && abs(got.height - wanted.height) < 0.000_1,
                                "\(label) in \(viewport): \(got) vs \(wanted)")
                    }
                }
            }
        }
    }

    /// Where the picture sits INSIDE the raster on screen, as fractions of the
    /// raster's own rect there. An identity assist places the bare raster,
    /// which is what a surface does to a frame that is already framed.
    private func framing(_ assist: ViewAssist, raw: CGSize,
                         in viewport: CGSize) -> CGRect? {
        guard let picture = assist.placement(sourceSize: raw, in: viewport),
              let raster = ViewAssist().placement(sourceSize: raw, in: viewport),
              raster.rect.width > 0, raster.rect.height > 0 else { return nil }
        return CGRect(
            x: (picture.rect.minX - raster.rect.minX) / raster.rect.width,
            y: (picture.rect.minY - raster.rect.minY) / raster.rect.height,
            width: picture.rect.width / raster.rect.width,
            height: picture.rect.height / raster.rect.height)
    }
}
