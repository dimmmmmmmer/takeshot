import CoreGraphics
import Foundation
import Testing

@testable import CaptureCore

/// **The preview has to show the truth.**
///
/// The owner asked for the arrangement to be visible before a run commits to it
/// ("в дейлизах хочется при настройке оверлеев ... а главное визуализации"), and
/// a preview drawn by its own code is a preview that can disagree with the burn
/// — silently, and only on the delivered file. So `previewImage` runs the real
/// `DailiesOverlay`, and these tests read its PIXELS.
///
/// They count PLATE COVERAGE — the share of a region darkened by a strip —
/// rather than mean brightness. A plate is a small, solid, much-darker rect: at
/// 320×180 it moves a quadrant's mean by about 4/255, which is inside the range
/// an unrelated change could wander through, while coverage of the corner it is
/// in reads far from zero and coverage of every other corner reads exactly
/// zero. That is the difference between a test that measures the layout and a
/// test that measures the render's average.
@Suite struct DailiesBurninPreviewTests {
    private let size = CGSize(width: 320, height: 180)
    /// The sheet's backdrop: a mid grey, so a plate (black at 0.55) is far
    /// darker than the frame behind it and no threshold guessing is needed.
    private let background = CGColor(gray: 0.22, alpha: 1)

    /// The share of `region` covered by something clearly darker than the
    /// background, 0…1.
    ///
    /// The bitmap is BGRA (premultipliedFirst, little-endian) and its memory
    /// rows run TOP-DOWN, which is the opposite of the drawing coordinate
    /// system's origin — so `region` is stated in the image's own top-left
    /// fractions, the way the layout states positions, and read straight.
    private func plateCoverage(_ image: CGImage,
                               in region: CGRect) throws -> Double {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(pixels.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: width, height: height,
                      bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)
                          ?? CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                          | CGBitmapInfo.byteOrder32Little.rawValue)
        }, "the sampling context could not be made")
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // The background as this bitmap actually stores it: the grey through
        // sRGB's transfer curve, read from a pixel the layout never touches
        // (dead centre — no position places a strip there).
        let middle = ((height / 2) * width + width / 2) * 4
        let plain = Double(pixels[middle])
        let x0 = Int(region.minX * CGFloat(width))
        let x1 = Int(region.maxX * CGFloat(width))
        let y0 = Int(region.minY * CGFloat(height))
        let y1 = Int(region.maxY * CGFloat(height))
        var dark = 0
        var count = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let offset = (y * width + x) * 4
                // Blue channel alone: the plate is neutral and so is the
                // background, and one channel is one comparison.
                if Double(pixels[offset]) < plain - 12 { dark += 1 }
                count += 1
            }
        }
        try #require(count > 0, "the region sampled no pixels")
        return Double(dark) / Double(count)
    }

    private let topLeft = CGRect(x: 0, y: 0, width: 0.5, height: 0.3)
    private let bottomRight = CGRect(x: 0.5, y: 0.7, width: 0.5, height: 0.3)

    /// A line sent to a corner puts a plate in THAT corner, and in no other.
    @Test func theStripAppearsInTheCornerItWasSentTo() throws {
        let up = try #require(DailiesOverlay.previewImage(
            size: size,
            texts: DailiesOverlay.Texts(clipName: "A001C001",
                                        clipNamePosition: .topLeft),
            background: background), "the preview rendered nothing")
        #expect(try plateCoverage(up, in: topLeft) > 0.05,
                "the strip was sent top-left and there is no plate there")
        #expect(try plateCoverage(up, in: bottomRight) == 0,
                "a strip appeared in a corner nothing was sent to")

        let down = try #require(DailiesOverlay.previewImage(
            size: size,
            texts: DailiesOverlay.Texts(clipName: "A001C001",
                                        clipNamePosition: .bottomRight),
            background: background))
        #expect(try plateCoverage(down, in: bottomRight) > 0.05,
                "the strip was sent bottom-right and there is no plate there")
        #expect(try plateCoverage(down, in: topLeft) == 0,
                "the strip stayed top-left after being moved")
    }

    /// An empty arrangement draws the frame and nothing else — so the corner
    /// test above is not passing on a preview that is plate everywhere.
    @Test func nothingEnabledLeavesThePlainFrame() throws {
        let bare = try #require(DailiesOverlay.previewImage(
            size: size, texts: DailiesOverlay.Texts(), background: background))
        for corner in [topLeft, bottomRight] {
            #expect(try plateCoverage(bare, in: corner) == 0,
                    "an empty arrangement drew a strip")
        }
    }

    /// Two lines sent to one corner both show, stacked — the case the picker
    /// makes reachable and the classic layout never could.
    @Test func twoLinesInOneCornerBothShow() throws {
        let one = try #require(DailiesOverlay.previewImage(
            size: size,
            texts: DailiesOverlay.Texts(clipName: "A001C001",
                                        clipNamePosition: .bottomRight),
            background: background))
        let two = try #require(DailiesOverlay.previewImage(
            size: size,
            texts: DailiesOverlay.Texts(clipName: "A001C001",
                                        project: "FILM · A001",
                                        clipNamePosition: .bottomRight,
                                        projectPosition: .bottomRight),
            background: background))
        #expect(try plateCoverage(two, in: bottomRight)
            > plateCoverage(one, in: bottomRight) * 1.5,
                "the second line did not add a plate — it landed on the first")
    }

    /// The timecode strip is drawn with a RUNNING value, not the template. The
    /// template exists so the plate does not resize as the digits run, and a
    /// preview of "00:00:00:00" would be checking a layout against a string the
    /// delivered file never shows.
    @Test func theTimecodeStripCarriesARunningValue() throws {
        let shown = try #require(DailiesOverlay.previewImage(
            size: size,
            texts: DailiesOverlay.Texts(timecodeTemplate: "00:00:00:00",
                                        timecodePosition: .topCenter),
            background: background, timecodeText: "01:23:45:12"))
        let blank = try #require(DailiesOverlay.previewImage(
            size: size,
            texts: DailiesOverlay.Texts(timecodeTemplate: "00:00:00:00",
                                        timecodePosition: .topCenter),
            background: background, timecodeText: " "))
        // The plate is the same either way; the digits are white, so the strip
        // with a value has LESS of its own area dark.
        let centre = CGRect(x: 0.3, y: 0, width: 0.4, height: 0.3)
        #expect(try plateCoverage(shown, in: centre) > 0.02,
                "the timecode plate is missing")
        #expect(try plateCoverage(shown, in: centre)
            < plateCoverage(blank, in: centre),
                "the timecode strip drew no digits")
    }
}
