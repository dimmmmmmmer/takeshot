import CoreImage
import Foundation
import Testing

@testable import CaptureCore

/// The geometry the operator aids are drawn with, and the one pass that used to
/// reach outside the picture.
///
/// Two things are pinned here. `ViewAssist.placement` is the aspect-fit +
/// punch-in transform, and it exists because there used to be two of them: the
/// renderer magnified and panned the image while the SwiftUI framelines stayed
/// nailed to the window. A frameline that does not move with the signal is worse
/// than none — it says "your 2.39 crop is here" about the wrong pixels. So the
/// numbers the overlays get and the numbers the renderer uses have to come out
/// of the same call, and a source stated in PIXELS has to place identically to
/// the same source stated as a bare ASPECT (which is all an overlay knows).
///
/// The second is focus peaking. Its edge detector is a convolution, and
/// CoreImage answers a sample taken past a finite image with transparent black:
/// on a flat frame that reads as the strongest edge in the picture and painted a
/// bright line along the frame border, which on a letterboxed player looks
/// exactly like peaking highlighting the letterbox.
struct AssistGeometryTests {
    // MARK: - placement

    private let viewport = CGSize(width: 1200, height: 800)
    private let hd = CGSize(width: 1920, height: 1080)

    private func assist(punchIn: Double = 1, panX: Double = 0,
                        panY: Double = 0) -> ViewAssist {
        var assist = ViewAssist()
        assist.punchIn = punchIn
        assist.panX = panX
        assist.panY = panY
        return assist
    }

    /// Unmagnified: the picture is centered and fits, letterboxed on the axis it
    /// runs out of first.
    @Test func anUnmagnifiedFrameIsCenteredAndFitted() throws {
        let placed = try #require(assist().placement(sourceSize: hd,
                                                     in: viewport))
        #expect(placed.rect.width == viewport.width, "the fit did not use the width")
        #expect(abs(placed.rect.height - 675) < 0.001) // 1200 / (16/9)
        #expect(placed.rect.midX == viewport.width / 2)
        #expect(placed.rect.midY == viewport.height / 2)
        #expect(abs(placed.scale - 1200.0 / 1920.0) < 0.000_001)
    }

    /// The overlays know an aspect, the renderer knows pixels. If those placed
    /// differently the frameline would sit next to the picture, not on it.
    @Test func pixelsAndAspectPlaceIdentically() throws {
        for punchIn in [1.0, 1.7, 4.0] {
            let state = assist(punchIn: punchIn, panX: 0.1, panY: -0.2)
            let fromPixels = try #require(state.placement(sourceSize: hd,
                                                          in: viewport))
            let fromAspect = try #require(state.placement(
                sourceSize: CGSize(width: 16.0 / 9.0, height: 1), in: viewport))
            #expect(fromPixels.rect.equalTo(fromAspect.rect),
                    "\(punchIn)x: \(fromPixels.rect) vs \(fromAspect.rect)")
        }
    }

    /// Punching in magnifies about the center: twice the picture, same middle.
    @Test func punchingInMagnifiesAboutTheCenter() throws {
        let plain = try #require(assist().placement(sourceSize: hd, in: viewport))
        let punched = try #require(assist(punchIn: 2).placement(sourceSize: hd,
                                                                in: viewport))
        #expect(abs(punched.rect.width - plain.rect.width * 2) < 0.001)
        #expect(abs(punched.rect.height - plain.rect.height * 2) < 0.001)
        #expect(punched.rect.midX == plain.rect.midX)
        #expect(punched.rect.midY == plain.rect.midY)
        #expect(abs(punched.scale - plain.scale * 2) < 0.000_001)
    }

    /// Pan moves the picture, and in the direction the operator's hand went:
    /// a positive pan slides the visible window right, so the image goes left.
    @Test func panningMovesThePictureAgainstTheWindow() throws {
        let punched = try #require(assist(punchIn: 2).placement(sourceSize: hd,
                                                                in: viewport))
        let panned = try #require(assist(punchIn: 2, panX: 0.1, panY: 0.25)
            .placement(sourceSize: hd, in: viewport))
        #expect(abs(panned.rect.midX
                    - (punched.rect.midX - 0.1 * punched.rect.width)) < 0.001)
        #expect(abs(panned.rect.midY
                    - (punched.rect.midY - 0.25 * punched.rect.height)) < 0.001)
        #expect(panned.rect.size == punched.rect.size)
    }

    /// Unmagnified there is nowhere to pan to, and a stale pan value must not
    /// shift the picture off center behind the operator's back.
    @Test func panIsIgnoredWhileNotPunchedIn() throws {
        let placed = try #require(assist(punchIn: 1, panX: 0.4, panY: 0.4)
            .placement(sourceSize: hd, in: viewport))
        #expect(placed.rect.midX == viewport.width / 2)
        #expect(placed.rect.midY == viewport.height / 2)
    }

    @Test func aDegenerateSourceOrViewportPlacesNothing() {
        #expect(assist().placement(sourceSize: .zero, in: viewport) == nil)
        #expect(assist().placement(sourceSize: hd, in: .zero) == nil)
    }

    // MARK: - limits

    /// At magnification s only 1/s of the frame is on screen, so the pan may
    /// travel (1 − 1/s)/2 before the picture's own edge comes into view. The
    /// clamp used to be a flat ±0.5 at every level, which let the operator pull
    /// letterbox into the middle of a 2x punch-in.
    @Test func thePanLimitFollowsTheMagnification() {
        #expect(assist().panLimit == 0)
        #expect(abs(assist(punchIn: 2).panLimit - 0.25) < 0.000_001)
        #expect(abs(assist(punchIn: 4).panLimit - 0.375) < 0.000_001)

        var state = assist(punchIn: 2)
        state.pan(by: CGSize(width: 5, height: -5))
        #expect(state.panX == 0.25 && state.panY == -0.25)

        // zooming back out has to bring the picture back with it
        state.setPunchIn(1)
        #expect(state.panX == 0 && state.panY == 0)
    }

    @Test func theMagnificationStaysInsideItsBounds() {
        var state = ViewAssist()
        state.setPunchIn(100)
        #expect(state.punchIn == ViewAssist.maxPunchIn)
        state.setPunchIn(0.2)
        #expect(state.punchIn == ViewAssist.minPunchIn)

        // a pinch arrives as a stream of small relative deltas
        state.setPunchIn(2)
        for _ in 0..<10 { state.magnify(by: 1.05) }
        #expect(state.punchIn > 2.5 && state.punchIn < 3.5)
        state.magnify(by: 0)      // nonsense from a bad event
        state.magnify(by: .nan)
        #expect(state.punchIn > 2.5)
    }

    @Test func panningUnmagnifiedDoesNothing() {
        var state = ViewAssist()
        state.pan(by: CGSize(width: 0.2, height: 0.2))
        #expect(state.panX == 0 && state.panY == 0)
    }

    // MARK: - anchored magnify (wheel and pinch zoom about the pointer)

    /// The image point under `anchor` before the zoom, as a fraction of the
    /// picture — and where that fraction lands after. Equal means the zoom
    /// stayed centered on the pointer.
    private func anchorDrift(_ state: ViewAssist, from before: ViewAssist,
                             anchor: CGPoint) throws -> CGSize {
        let placedBefore = try #require(before.placement(sourceSize: hd,
                                                         in: viewport))
        let u = (anchor.x - placedBefore.rect.minX) / placedBefore.rect.width
        let v = (anchor.y - placedBefore.rect.minY) / placedBefore.rect.height
        let placedAfter = try #require(state.placement(sourceSize: hd,
                                                       in: viewport))
        return CGSize(
            width: placedAfter.rect.minX + u * placedAfter.rect.width - anchor.x,
            height: placedAfter.rect.minY + v * placedAfter.rect.height - anchor.y)
    }

    /// A wheel tick over a detail zooms INTO that detail: the pixel under the
    /// pointer stays under the pointer, zooming in and back out again.
    @Test func anchoredMagnifyKeepsThePointUnderThePointer() throws {
        let anchor = CGPoint(x: 900, y: 300)
        for (start, factor) in [(2.0, 1.5), (1.0, 2.0), (3.0, 1 / 1.2)] {
            let before = assist(punchIn: start)
            var state = before
            state.magnify(by: factor, at: anchor, sourceSize: hd, in: viewport)
            #expect(abs(state.punchIn - start * factor) < 0.000_001)
            let drift = try anchorDrift(state, from: before, anchor: anchor)
            #expect(abs(drift.width) < 0.001 && abs(drift.height) < 0.001,
                    "\(start)x·\(factor) drifted \(drift) under the pointer")
        }
    }

    /// The anchor never wins against the clamps: past the magnification bounds
    /// or the pan limit the picture pins to its edge instead of dragging
    /// letterbox in — and zooming all the way back out recenters, exactly as
    /// the un-anchored path does.
    @Test func anchoredMagnifyRespectsTheClamps() {
        var state = assist(punchIn: 2)
        // the frame's top-left corner, well past what the pan limit can honor
        for _ in 0..<10 {
            state.magnify(by: 1.8, at: .zero, sourceSize: hd, in: viewport)
        }
        #expect(state.punchIn == ViewAssist.maxPunchIn)
        let limit = state.panLimit
        #expect(abs(state.panX) <= limit && abs(state.panY) <= limit)

        state.magnify(by: 0.01, at: CGPoint(x: 900, y: 300),
                      sourceSize: hd, in: viewport)
        #expect(state.punchIn == ViewAssist.minPunchIn)
        #expect(state.panX == 0 && state.panY == 0,
                "zooming out left the picture parked off-center")

        // nonsense factors change nothing (a bad event mid-stream)
        state.setPunchIn(2)
        let before = state
        state.magnify(by: 0, at: .zero, sourceSize: hd, in: viewport)
        state.magnify(by: .nan, at: .zero, sourceSize: hd, in: viewport)
        #expect(state == before)
    }

    /// With nothing to place (no signal yet) the anchor is meaningless but the
    /// zoom still has to work — the level changes, clamped, pan untouched.
    @Test func anchoredMagnifyWithoutAPlacementStillZooms() {
        var state = assist(punchIn: 2)
        state.magnify(by: 2, at: CGPoint(x: 10, y: 10),
                      sourceSize: .zero, in: viewport)
        #expect(state.punchIn == 4)
        #expect(state.panX == 0 && state.panY == 0)
    }

    // MARK: - peaking stays on the picture

    /// R minus G per pixel of the assist output — the peaking overlay is red
    /// only, so anything above zero here is peaking.
    private func peakingLift(over source: CIImage,
                             intensity: Double = 12) throws -> [[Int]] {
        var assist = ViewAssist()
        assist.peakingOn = true
        assist.peakingIntensity = intensity
        let output = AssistFilters.applied(source, assist: assist)
        #expect(output.extent.equalTo(source.extent),
                "the assist pass grew past the video rect: \(output.extent)")

        let width = Int(source.extent.width)
        let height = Int(source.extent.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            context.render(output, toBitmap: base, rowBytes: width * 4,
                           bounds: source.extent, format: CIFormat.RGBA8,
                           colorSpace: nil)
        }
        return (0..<height).map { row in
            (0..<width).map { column in
                let index = (row * width + column) * 4
                return Int(pixels[index]) - Int(pixels[index + 1])
            }
        }
    }

    /// A flat frame has no edges anywhere — including at its own border, which
    /// is where the pass used to paint a bright line into the letterbox.
    @Test func peakingLeavesAFlatFrameAlone() throws {
        let extent = CGRect(x: 0, y: 0, width: 32, height: 18)
        let flat = CIImage(color: CIColor(red: 0.35, green: 0.35, blue: 0.35))
            .cropped(to: extent)

        let lift = try peakingLift(over: flat)
        let worst = lift.flatMap { $0 }.max() ?? 0
        #expect(worst <= 2, "peaking lit up a frame with nothing in it: \(worst)")
    }

    /// And the positive control: a real edge inside the picture still peaks, so
    /// the clamp above did not simply switch the tool off.
    @Test func peakingStillFindsARealEdge() throws {
        let extent = CGRect(x: 0, y: 0, width: 32, height: 18)
        let dark = CIImage(color: CIColor(red: 0.1, green: 0.1, blue: 0.1))
            .cropped(to: CGRect(x: 0, y: 0, width: 16, height: 18))
        let light = CIImage(color: CIColor(red: 0.9, green: 0.9, blue: 0.9))
            .cropped(to: CGRect(x: 16, y: 0, width: 16, height: 18))
        let split = dark.composited(over: light).cropped(to: extent)

        let lift = try peakingLift(over: split)
        let worst = lift.flatMap { $0 }.max() ?? 0
        #expect(worst > 20, "the edge in the middle did not peak: \(worst)")
        // and it is where the edge is, not along the border
        let middleRow = lift[lift.count / 2]
        #expect((middleRow[14...17].max() ?? 0) > 20)
        #expect(middleRow[0] <= 2 && middleRow[middleRow.count - 1] <= 2)
    }

    /// RGBA bytes of an image, rendered exactly as `peakingLift` renders.
    private func rendered(_ image: CIImage) -> [UInt8] {
        let width = Int(image.extent.width)
        let height = Int(image.extent.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            context.render(image, toBitmap: base, rowBytes: width * 4,
                           bounds: image.extent, format: CIFormat.RGBA8,
                           colorSpace: nil)
        }
        return pixels
    }

    /// The operator's peaking color reaches the pixels: over a gray source the
    /// overlay is the ONLY thing that can move a channel away from its
    /// neighbors, so per preset the channels its tint names must lift at the
    /// edge and the others must not move at all.
    @Test func peakingEdgesWearTheChosenColor() throws {
        let extent = CGRect(x: 0, y: 0, width: 32, height: 18)
        let dark = CIImage(color: CIColor(red: 0.1, green: 0.1, blue: 0.1))
            .cropped(to: CGRect(x: 0, y: 0, width: 16, height: 18))
        let light = CIImage(color: CIColor(red: 0.9, green: 0.9, blue: 0.9))
            .cropped(to: CGRect(x: 16, y: 0, width: 16, height: 18))
        let split = dark.composited(over: light).cropped(to: extent)
        let source = rendered(split)

        for color in ViewAssist.PeakingColor.allCases {
            var assist = ViewAssist()
            assist.peakingOn = true
            assist.peakingColor = color
            let output = rendered(AssistFilters.applied(split, assist: assist))

            let tint = [color.components.red, color.components.green,
                        color.components.blue]
            for channel in 0..<3 {
                let lift = stride(from: channel, to: output.count, by: 4)
                    .map { Int(output[$0]) - Int(source[$0]) }
                    .max() ?? 0
                if tint[channel] == 1 {
                    #expect(lift > 20,
                            "\(color) never lit channel \(channel): \(lift)")
                } else {
                    #expect(lift <= 2,
                            "\(color) bled into channel \(channel): \(lift)")
                }
            }
        }
    }
}
