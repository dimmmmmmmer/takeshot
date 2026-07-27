import CoreImage
import Foundation
import Testing
@testable import CaptureCore

/// Compare geometry is shared by the playback tap and the live pipeline, so a
/// seam that drifts here shows up as two surfaces disagreeing on set. Rendering
/// goes through the software renderer: deterministic and GPU-free on CI.
struct CompareCompositorTests {
    private let context = CIContext(options: [.useSoftwareRenderer: true])
    private let side = 64
    private var extent: CGRect { CGRect(x: 0, y: 0, width: side, height: side) }

    private func solid(_ color: CIColor) -> CIImage {
        CIImage(color: color).cropped(to: extent)
    }

    /// RGBA of one pixel, sampled in CoreImage coordinates (origin bottom-left).
    private func pixel(_ image: CIImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        var bytes = [UInt8](repeating: 0, count: 4)
        context.render(image, toBitmap: &bytes, rowBytes: 4,
                       bounds: CGRect(x: x, y: y, width: 1, height: 1),
                       format: .RGBA8, colorSpace: nil)
        return (bytes[0], bytes[1], bytes[2])
    }

    private var red: CIImage { solid(CIColor(red: 1, green: 0, blue: 0)) }
    private var blue: CIImage { solid(CIColor(red: 0, green: 0, blue: 1)) }

    @Test func offReturnsTheFrontImageUntouched() {
        let composed = CompareCompositor.compose(front: red, back: blue, mode: .off)
        #expect(pixel(composed, x: 1, y: 1).r == 255)
        #expect(pixel(composed, x: side - 2, y: side - 2).r == 255)
    }

    @Test func verticalWipeKeepsFrontOnTheLeftOfTheSeam() {
        let composed = CompareCompositor.compose(
            front: red, back: blue, mode: .wipe(axis: .vertical, position: 0.5))
        #expect(pixel(composed, x: 4, y: side / 2).r == 255)          // left: front
        #expect(pixel(composed, x: side - 4, y: side / 2).b == 255)   // right: back
    }

    /// The seam must follow the operator's drag: SwiftUI drags a horizontal wipe
    /// from the top, while CoreImage counts y from the bottom — the place where
    /// an inverted axis would hide.
    @Test func horizontalWipeGrowsFromTheTop() {
        let composed = CompareCompositor.compose(
            front: red, back: blue, mode: .wipe(axis: .horizontal, position: 0.25))
        #expect(pixel(composed, x: side / 2, y: side - 4).r == 255)   // top quarter: front
        #expect(pixel(composed, x: side / 2, y: 4).b == 255)          // bottom: back
    }

    @Test func diagonalWipeSplitsOnTheAntiDiagonal() {
        let composed = CompareCompositor.compose(
            front: red, back: blue, mode: .wipe(axis: .diagonal, position: 0.5))
        // top-left corner belongs to the front side, bottom-right to the back
        #expect(pixel(composed, x: 2, y: side - 2).r == 255)
        #expect(pixel(composed, x: side - 2, y: 2).b == 255)
    }

    @Test func wipeAtTheExtremesShowsOneImageOnly() {
        let allBack = CompareCompositor.compose(
            front: red, back: blue, mode: .wipe(axis: .vertical, position: 0))
        #expect(pixel(allBack, x: 2, y: 2).b == 255)
        #expect(pixel(allBack, x: side - 2, y: side - 2).b == 255)

        let allFront = CompareCompositor.compose(
            front: red, back: blue, mode: .wipe(axis: .vertical, position: 1))
        #expect(pixel(allFront, x: 2, y: 2).r == 255)
        #expect(pixel(allFront, x: side - 2, y: side - 2).r == 255)
    }

    @Test func blendFadesBetweenTheTwoImages() {
        let back = CompareCompositor.compose(front: red, back: blue,
                                             mode: .blend(opacity: 0))
        #expect(pixel(back, x: side / 2, y: side / 2).b == 255)

        let front = CompareCompositor.compose(front: red, back: blue,
                                              mode: .blend(opacity: 1))
        #expect(pixel(front, x: side / 2, y: side / 2).r == 255)

        // halfway: both channels present, neither at full strength
        let middle = CompareCompositor.compose(front: red, back: blue,
                                               mode: .blend(opacity: 0.5))
        let sample = pixel(middle, x: side / 2, y: side / 2)
        #expect(sample.r > 40 && sample.r < 215)
        #expect(sample.b > 40 && sample.b < 215)
    }

    /// A stretched image would make the geometric comparison meaningless, so a
    /// mismatched source is letterboxed instead.
    @Test func fittedLetterboxesRatherThanStretches() {
        let wide = CGRect(x: 0, y: 0, width: 128, height: 64)
        let square = solid(CIColor(red: 0, green: 1, blue: 0)) // 64x64
        let fitted = CompareCompositor.fitted(square, into: wide)

        #expect(fitted.extent.width == 128)
        // the image keeps its square shape in the middle...
        #expect(pixel(fitted, x: 64, y: 32).g == 255)
        // ...and the sides are black bars, not stretched picture
        #expect(pixel(fitted, x: 2, y: 32).g == 0)
        #expect(pixel(fitted, x: 126, y: 32).g == 0)
    }

    @Test func fittedIsANoOpWhenTheSizesAlreadyMatch() {
        let image = solid(CIColor(red: 0, green: 1, blue: 0))
        let fitted = CompareCompositor.fitted(image, into: extent)
        #expect(fitted.extent == image.extent)
        #expect(pixel(fitted, x: 2, y: 2).g == 255)
    }
}
