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

    /// **The grid, in pixels — and the codes come through untouched.**
    ///
    /// Two cameras of two known levels come back side by side, in the order the
    /// page labels them, at exactly the codes they went in as. The second half
    /// of that is the contract every stage in this display path answers to: the
    /// buffers hold 709-encoded codes, and a managed render here would shift a
    /// picture the operator is judging exposure on. Colour-managing this pass
    /// by accident reads as a grid a few per cent off the app's own picture,
    /// which is the sort of thing nobody notices until a DP does.
    @Test func theComposedGridPutsEachCameraInItsCellAtItsOwnCodes() throws {
        let context = CIContext(options: [.cacheIntermediates: false])
        let canvas = CGRect(x: 0, y: 0, width: 320, height: 180)
        let left: CIImage = try Self.flat(0x40, width: 320, height: 180)
        let right: CIImage = try Self.flat(0xC0, width: 320, height: 180)
        let image = MultiviewComposer
            .placed(right, in: MultiviewComposer.cell(camera: 1, cameras: 2,
                                                      in: canvas))
            .composited(over: MultiviewComposer
                .placed(left, in: MultiviewComposer.cell(camera: 0, cameras: 2,
                                                         in: canvas)))
            .cropped(to: canvas)
        let out: CVPixelBuffer = try Self.rendered(image, in: canvas,
                                                   context: context)

        // Sampled in the vertical middle of each half, where the letterbox bars
        // are not: a 16:9 source into an 8:9 cell keeps its width and gains
        // bars above and below.
        let leftLevel: Int = Self.level(of: out, atX: 80, y: 90)
        let rightLevel: Int = Self.level(of: out, atX: 240, y: 90)
        #expect(leftLevel == 0x40, "camera 0 read \(leftLevel)")
        #expect(rightLevel == 0xC0, "camera 1 read \(rightLevel)")
        // And the bars really are black, so a tile is never the picture beside
        // it stretched into the margin — which is the failure `letterboxed`
        // exists for, on the macOS 15 runner in particular.
        #expect(Self.level(of: out, atX: 80, y: 3) == 0,
                "camera 0's letterbox bar is \(Self.level(of: out, atX: 80, y: 3))")
    }

    /// A flat field of one code, read the way the display path reads a frame:
    /// raw codes, no colour space.
    private static func flat(_ code: UInt8, width: Int,
                             height: Int) throws -> CIImage {
        let out: CVPixelBuffer = try buffer(width: width, height: height)
        CVPixelBufferLockBaseAddress(out, [])
        if let base = CVPixelBufferGetBaseAddress(out) {
            let stride = CVPixelBufferGetBytesPerRow(out)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                for x in 0..<width {
                    let pixel = bytes + y * stride + x * 4
                    pixel[0] = code
                    pixel[1] = code
                    pixel[2] = code
                    pixel[3] = 0xFF
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(out, [])
        return CIImage(cvPixelBuffer: out, options: [.colorSpace: NSNull()])
    }

    private static func rendered(_ image: CIImage, in canvas: CGRect,
                                 context: CIContext) throws -> CVPixelBuffer {
        let out: CVPixelBuffer = try buffer(width: Int(canvas.width),
                                            height: Int(canvas.height))
        let destination = CIRenderDestination(pixelBuffer: out)
        destination.colorSpace = nil
        let task = try context.startTask(toRender: image, to: destination)
        try task.waitUntilCompleted()
        return out
    }

    private static func buffer(width: Int,
                               height: Int) throws -> CVPixelBuffer {
        var made: CVPixelBuffer?
        let attributes: CFDictionary =
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_32BGRA, attributes, &made)
        return try #require(made)
    }

    private static func level(of buffer: CVPixelBuffer, atX x: Int,
                              y: Int) -> Int {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return -1 }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let pixel = base.advanced(by: y * stride + x * 4)
            .assumingMemoryBound(to: UInt8.self)
        return Int(pixel[2]) // BGRA: red
    }
}
