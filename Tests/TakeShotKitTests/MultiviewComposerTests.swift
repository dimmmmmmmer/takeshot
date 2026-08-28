import CaptureCore
@preconcurrency import CoreImage
import CoreVideo
import Foundation
import Testing

@testable import TakeShotKit

/// The grid picture: where each camera lands, and that it lands there in
/// pixels.
///
/// The layout half is pure arithmetic and is tested as such — every interesting
/// case is a boundary (a last row with a hole in it, a canvas that does not
/// divide evenly, camera 0 having to be top LEFT in a coordinate system whose
/// origin is bottom left). The render half is one composed frame, sampled: a
/// layout that is right on paper and drawn upside down is a grid where the
/// director is watching B-cam under a label that says A.
struct MultiviewComposerTests {
    private static let canvas = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    // MARK: - the layout

    /// The shape the `/cameras` page draws, so a phone switching between the
    /// two is looking at one arrangement rather than two opinions about it.
    @Test func theLayoutFollowsTheCameraCount() {
        #expect(MultiviewComposer.columns(cameras: 1) == 1)
        #expect(MultiviewComposer.rows(cameras: 1) == 1)
        #expect(MultiviewComposer.columns(cameras: 2) == 2)
        #expect(MultiviewComposer.rows(cameras: 2) == 1)
        #expect(MultiviewComposer.columns(cameras: 4) == 2)
        #expect(MultiviewComposer.rows(cameras: 4) == 2)
        // Three wraps onto the same 2-across grid with a hole in the last row,
        // rather than squeezing three columns nobody can read on a handset.
        #expect(MultiviewComposer.columns(cameras: 3) == 2)
        #expect(MultiviewComposer.rows(cameras: 3) == 2)
        // A count that cannot happen still has to produce a rectangle.
        #expect(MultiviewComposer.rows(cameras: 0) == 1)
    }

    /// Camera 0 is the TOP LEFT cell, which is not automatic: CoreImage's
    /// origin is bottom left, so a row index used directly puts A-cam under
    /// B-cam and everything the page labels is then wrong.
    @Test func cameraZeroIsTheTopLeftCell() {
        let cell = MultiviewComposer.cell(camera: 0, cameras: 4,
                                          in: Self.canvas)
        #expect(cell == CGRect(x: 0, y: 540, width: 960, height: 540))
        let second = MultiviewComposer.cell(camera: 1, cameras: 4,
                                            in: Self.canvas)
        #expect(second == CGRect(x: 960, y: 540, width: 960, height: 540))
        let third = MultiviewComposer.cell(camera: 2, cameras: 4,
                                           in: Self.canvas)
        #expect(third == CGRect(x: 0, y: 0, width: 960, height: 540))
    }

    /// One camera gets the whole canvas — the grid IS the clean picture then,
    /// and a tile inset inside a black frame would be a smaller picture for no
    /// reason.
    @Test func oneCameraFillsTheCanvas() {
        #expect(MultiviewComposer.cell(camera: 0, cameras: 1, in: Self.canvas)
                    == Self.canvas)
    }

    /// The cells tile the canvas: no overlap, and together they cover it.
    ///
    /// Checked as area rather than by comparing rectangles, because that is the
    /// property that matters — a rounding change that made the cells overlap by
    /// a pixel would still pass a list of expected rectangles written to match
    /// it.
    @Test func theCellsTileTheCanvasWithoutOverlapping() {
        for cameras: Int in 1...6 {
            let cells: [CGRect] = (0..<cameras).map {
                MultiviewComposer.cell(camera: $0, cameras: cameras,
                                       in: Self.canvas)
            }
            for (index, cell) in cells.enumerated() {
                #expect(Self.canvas.contains(cell),
                        "\(cameras) cameras: cell \(index) leaves the canvas")
                for other in cells[(index + 1)...] {
                    let overlap: CGRect = cell.intersection(other)
                    #expect(overlap.isNull || overlap.width == 0
                                || overlap.height == 0,
                            "\(cameras) cameras: cells overlap at \(overlap)")
                }
            }
            let covered: CGFloat = cells.reduce(0) { $0 + $1.width * $1.height }
            let whole: CGFloat = Self.canvas.width * Self.canvas.height
            let rows: Int = MultiviewComposer.rows(cameras: cameras)
            let columns: Int = MultiviewComposer.columns(cameras: cameras)
            let holes: Int = rows * columns - cameras
            let expected: CGFloat = whole
                * CGFloat(cameras) / CGFloat(rows * columns)
            #expect(abs(covered - expected) < 1,
                    "\(cameras) cameras, \(holes) empty: covered \(covered) of \(whole)")
        }
    }

    // MARK: - the render

    /// An out-of-range camera index cannot draw outside the canvas.
    ///
    /// A count and an index arriving from two places (the channel list and a
    /// tap installed a moment earlier) is exactly where an off-by-one lives,
    /// and the honest failure is a tile in the wrong cell rather than a render
    /// off the edge of the frame.
    @Test func anIndexPastTheCountStaysInsideTheCanvas() {
        let cell = MultiviewComposer.cell(camera: 9, cameras: 2,
                                          in: Self.canvas)
        #expect(Self.canvas.contains(cell))
    }

    /// A tile is aspect-FIT into its cell and letterboxed, never cropped: the
    /// edges of frame are the one thing a monitoring surface must not hide.
    @Test func aTileIsFittedIntoItsCellAndNotCropped() {
        // A 16:9 image into a 16:9 cell that is half as wide: it fits to the
        // width and gets bars top and bottom, so the drawn picture is the whole
        // of the source.
        let cell = CGRect(x: 0, y: 0, width: 960, height: 540)
        let wide = CIImage(color: .white)
            .cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 540))
        let placed = MultiviewComposer.placed(wide, in: cell)
        #expect(placed.extent == cell,
                "the placement did not fill its cell: \(placed.extent)")
    }

    /// **The grid, in pixels, through the composer itself — and the codes come
    /// through untouched.**
    ///
    /// Driven the way the app drives it (offer per camera, sink on the
    /// composer's own queue) rather than by reassembling the layout here, so
    /// what is checked is the pass that actually runs: camera 0 being
    /// the clock, the tiles landing in the cells the page labels, and the codes
    /// arriving unchanged. That last one is the contract every stage in this
    /// display path answers to — the buffers hold 709-encoded codes, and a
    /// managed render here would shift a picture the operator is judging
    /// exposure on by a few per cent, which is the sort of thing nobody notices
    /// until a DP does.
    @Test func theComposerPutsEachCameraInItsCellAtItsOwnCodes() async throws {
        let composed = ComposedFrames()
        let composer = MultiviewComposer { buffer, rate in
            composed.record(buffer, rate: rate)
        }
        composer.setCameraCount(2)
        // The B-cam's tile arrives first and waits; camera 0 is the clock.
        composer.offer(try ComposerProbe.buffer(code: 0xC0, width: 320, height: 180),
                       camera: 1, framesPerSecond: 0)
        try await Task.sleep(for: .milliseconds(50))
        #expect(composed.count == 0,
                "a camera that is not camera 0 composed a frame on its own")

        composer.offer(try ComposerProbe.buffer(code: 0x40, width: 320, height: 180),
                       camera: 0, framesPerSecond: 25)
        #expect(await ControllerWait.untilWritten { composed.count > 0 },
                "camera 0 composed nothing")
        let out: CVPixelBuffer = try #require(composed.latest)
        #expect(composed.rate == 25, "camera 0's rate did not travel with it")
        #expect(CVPixelBufferGetWidth(out) == 320,
                "the canvas did not follow camera 0's raster")

        // Sampled in the vertical middle of each half, where the letterbox bars
        // are not: a 16:9 source into an 8:9 cell keeps its width and gains
        // bars above and below.
        let leftLevel: Int = ComposerProbe.level(of: out, atX: 80, y: 90)
        let rightLevel: Int = ComposerProbe.level(of: out, atX: 240, y: 90)
        #expect(leftLevel == 0x40, "camera 0 read \(leftLevel)")
        #expect(rightLevel == 0xC0, "camera 1 read \(rightLevel)")
        // And the bars really are black, so a tile is never the picture beside
        // it stretched into the margin — which is the failure `letterboxed`
        // exists for, on the macOS 15 runner in particular.
        #expect(ComposerProbe.level(of: out, atX: 80, y: 3) == 0,
                "the letterbox bar read \(ComposerProbe.level(of: out, atX: 80, y: 3))")
        composer.stop()
    }

    /// A single camera is handed straight back: the grid IS the clean picture
    /// then, and a scale-to-self plus a letterbox with no bars would be a whole
    /// render pass for an identity.
    @Test func oneCameraIsPassedThroughWithoutARenderPass() async throws {
        let composed = ComposedFrames()
        let composer = MultiviewComposer { buffer, rate in
            composed.record(buffer, rate: rate)
        }
        let source: CVPixelBuffer = try ComposerProbe.buffer(code: 0x77, width: 320,
                                                    height: 180)
        composer.offer(source, camera: 0, framesPerSecond: 25)
        #expect(await ControllerWait.untilWritten { composed.count > 0 })
        #expect(composed.latest === source,
                "one camera still cost a render pass")
        composer.stop()
    }

    /// **What the grid picture costs per frame**, which is the one genuinely
    /// new piece of per-frame work this choice adds.
    ///
    /// Opt-in like the rest of this project's timings:
    ///
    ///     TAKESHOT_BENCH=1 scripts/test.sh --filter MultiviewComposer
    ///
    /// and nothing here asserts on a clock. What it is NOT is a cost to the
    /// frame path: this runs on `com.takeshot.multiview.compose`, and the
    /// display queue's whole involvement is one `dispatch_async`. It is paid
    /// only while somebody is watching the grid, and once however many phones
    /// are watching it.
    @Test(.enabled(if: ComposerProbe.timed))
    func theComposeCostPerFrame() async throws {
        for (name, width, height) in [("1080p", 1920, 1080),
                                      ("UHD", 3840, 2160)] {
            for cameras: Int in [1, 2, 4] {
                let composed = ComposedFrames()
                let composer = MultiviewComposer { buffer, rate in
                    composed.record(buffer, rate: rate)
                }
                composer.setCameraCount(cameras)
                for camera: Int in 1..<max(1, cameras) {
                    composer.offer(try ComposerProbe.buffer(code: 0x80, width: width,
                                                   height: height),
                                   camera: camera, framesPerSecond: 25)
                }
                let lead: CVPixelBuffer = try ComposerProbe.buffer(code: 0x40,
                                                            width: width,
                                                            height: height)
                var samples: [Double] = []
                for run: Int in 0..<25 {
                    // Signalled rather than polled: a poll interval is tens of
                    // milliseconds and would BE the measurement.
                    composed.arm()
                    let start = DispatchTime.now().uptimeNanoseconds
                    composer.offer(lead, camera: 0, framesPerSecond: 25)
                    composed.waitForFrame()
                    let elapsed = Double(
                        DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                    if run >= 5 { samples.append(elapsed) } // warm the context
                }
                samples.sort()
                print(String(format: "COMPOSEBENCH %@ x%d: min %.3f ms  median %.3f ms",
                             name, cameras, samples[0],
                             samples[samples.count / 2]))
                composer.stop()
            }
        }
    }
}
