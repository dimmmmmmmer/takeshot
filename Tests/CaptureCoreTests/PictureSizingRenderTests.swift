import CoreImage
import CoreVideo
import Foundation
import Testing

@testable import CaptureCore

/// **The pixels, and the sentence that has to be true in both coordinate
/// spaces.**
///
/// `PictureSizing.transform` is y-DOWN — the space the mouse, the framelines
/// and the eyedropper are in — and `applied` is y-UP, because that is
/// CoreImage's. Two spellings of one transform is exactly the shape of defect
/// this app has already paid for, so these tests render a MARK and look for it
/// where the other half says it should be. A sign error anywhere in either
/// chain fails them.
@Suite struct PictureSizingRenderTests {
    private let frame = CGRect(x: 0, y: 0, width: 64, height: 32)
    /// Where the mark is in the source, in the same y-down pixel coordinates
    /// the transform speaks: column 24, row 10, counting from the top-left.
    ///
    /// Off-centre in BOTH axes, so a rotation that turned the wrong way or an
    /// axis that got swapped moves it somewhere this test can see — and not so
    /// far off-centre that a 2× zoom pushes it off the frame, which is the
    /// first version of this test finding nothing at all to measure.
    private let mark = CGPoint(x: 24.5, y: 10.5)

    /// A black frame with a white 3×3 block around `mark`.
    private func marked() -> CVPixelBuffer {
        let buffer = TestMedia.pixelBuffer(width: 64, height: 32)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return buffer }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for row in 0..<32 {
            let line = bytes + row * rowBytes
            for column in 0..<64 {
                let hit = abs(Double(row) + 0.5 - mark.y) <= 1.5
                    && abs(Double(column) + 0.5 - mark.x) <= 1.5
                let level: UInt8 = hit ? 255 : 0
                line[column * 4] = level
                line[column * 4 + 1] = level
                line[column * 4 + 2] = level
                line[column * 4 + 3] = 255
            }
        }
        return buffer
    }

    /// The centroid of everything brighter than half scale, in the SAME y-down
    /// pixel coordinates — row and column of the rendered buffer.
    private func brightCentroid(of buffer: CVPixelBuffer) -> CGPoint? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var sumX = 0.0, sumY = 0.0, weight = 0.0
        for row in 0..<CVPixelBufferGetHeight(buffer) {
            let line = bytes + row * rowBytes
            for column in 0..<CVPixelBufferGetWidth(buffer) where line[column * 4] > 128 {
                sumX += Double(column) + 0.5
                sumY += Double(row) + 0.5
                weight += 1
            }
        }
        guard weight > 0 else { return nil }
        return CGPoint(x: sumX / weight, y: sumY / weight)
    }

    private func render(_ image: CIImage) -> CVPixelBuffer? {
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, Int(frame.width),
                            Int(frame.height), kCVPixelFormatType_32BGRA,
                            attrs as CFDictionary, &buffer)
        guard let buffer else { return nil }
        let destination = CIRenderDestination(pixelBuffer: buffer)
        destination.colorSpace = nil
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let task = try? context.startTask(toRender: image, to: destination),
              (try? task.waitUntilCompleted()) != nil else { return nil }
        return buffer
    }

    private func sized(_ sizing: PictureSizing) -> CVPixelBuffer? {
        let image = CIImage(cvPixelBuffer: marked(),
                            options: [.colorSpace: NSNull()])
        return render(sizing.applied(to: image, in: frame,
                                     letterbox: CIColor(red: 0, green: 0, blue: 0)))
    }

    /// **The mark lands where the transform says it does** — for every affine
    /// control there is, one at a time, so a wrong sign has nowhere to hide.
    @Test func theRenderedPictureLandsWhereTheTransformSaysItDoes() throws {
        var zoomed = PictureSizing()
        zoomed.setZoom(2)
        var panned = PictureSizing()
        panned.setZoom(2)
        panned.panX = 0.05
        panned.panY = -0.1
        panned.clampPan()
        var turned = PictureSizing()
        turned.rotation = 90
        var mirrored = PictureSizing()
        mirrored.flipH = true
        var flipped = PictureSizing()
        flipped.flipV = true
        var stretched = PictureSizing()
        stretched.height = 0.5
        var shrunk = PictureSizing()
        shrunk.setZoom(0.5)

        for sizing in [PictureSizing(), zoomed, panned, turned, mirrored,
                       flipped, stretched, shrunk] {
            let matrix = try #require(sizing.transform(sourceSize: frame.size,
                                                       in: frame.size))
            let expected = mark.applying(matrix)
            let rendered = try #require(sized(sizing), "nothing rendered")
            let found = try #require(brightCentroid(of: rendered), """
                \(sizing) put the mark nowhere on the frame — expected it at \
                \(expected)
                """)
            #expect(abs(found.x - expected.x) < 1.5, """
                \(sizing): the mark rendered at column \(found.x), the \
                transform says \(expected.x)
                """)
            #expect(abs(found.y - expected.y) < 1.5, """
                \(sizing): the mark rendered at row \(found.y), the transform \
                says \(expected.y)
                """)
        }
    }

    /// An identity sizing over a frame the picture already fills is the
    /// picture itself — the same object, not an equal one. That is the
    /// contract a take's bit depth rests on: no resample, no bake, no reason
    /// to drop the wire codes.
    @Test func anIdentitySizingHandsTheSameImageBack() {
        let image = CIImage(cvPixelBuffer: marked(),
                            options: [.colorSpace: NSNull()])
        let out = PictureSizing().applied(to: image, in: image.extent,
                                          letterbox: CIColor(red: 0, green: 0,
                                                             blue: 0))
        #expect(out === image, "an identity sizing built a new image")
    }

    /// **A yaw makes the far edge shorter than the near one.** That is the
    /// difference between a perspective and a shear, and it is the whole
    /// reason the control is called yaw: a shear keeps both edges the same
    /// height and just leans the picture over.
    @Test func aYawMakesTheFarEdgeShorterThanTheNear() throws {
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1))
            .cropped(to: frame)
        var sizing = PictureSizing()
        sizing.yaw = 35
        let rendered = try #require(render(sizing.applied(
            to: white, in: frame, letterbox: CIColor(red: 0, green: 0, blue: 0))))
        // Its OWN edges, not the frame's: a yaw turns the card away, so it no
        // longer reaches the sides of the frame at all.
        let columns = (0..<Int(frame.width))
            .map { brightRun(in: rendered, column: $0) }
        let first = try #require(columns.firstIndex { $0 > 0 },
                                 "the yawed picture rendered nothing")
        let last = try #require(columns.lastIndex { $0 > 0 })
        #expect(last - first > 8, """
            the yawed picture is only \(last - first) columns wide — there is \
            nothing to compare
            """)
        #expect(abs(columns[first] - columns[last]) > 2, """
            its two edges came back \(columns[first]) and \(columns[last]) \
            pixels tall — a yaw that leaves them equal is a shear, not a \
            perspective
            """)
    }

    /// How many bright pixels one column holds — the height of the picture
    /// at that edge.
    private func brightRun(in buffer: CVPixelBuffer, column: Int) -> Int {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var count = 0
        for row in 0..<CVPixelBufferGetHeight(buffer)
        where (bytes + row * rowBytes)[column * 4] > 128 {
            count += 1
        }
        return count
    }
}
