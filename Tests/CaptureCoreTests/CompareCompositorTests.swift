import CoreImage
import CoreVideo
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

    private struct Sample {
        let r: UInt8
        let g: UInt8
        let b: UInt8
    }

    /// RGB of one pixel, sampled in CoreImage coordinates (origin bottom-left).
    private func pixel(_ image: CIImage, x: Int, y: Int) -> Sample {
        var bytes = [UInt8](repeating: 0, count: 4)
        context.render(image, toBitmap: &bytes, rowBytes: 4,
                       bounds: CGRect(x: x, y: y, width: 1, height: 1),
                       format: .RGBA8, colorSpace: nil)
        return Sample(r: bytes[0], g: bytes[1], b: bytes[2])
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

    // MARK: - difference

    /// An image whose 8-bit code is chosen per COLUMN, entering the compositor
    /// with color management off — exactly how every real caller hands frames
    /// in. `solid()` above would not do here: a `CIColor` carries sRGB, the
    /// context linearizes it on entry, and a 10-code delta comes back as 7.
    /// The wipe/blend tests get away with it because 0 and 255 are fixed
    /// points of that conversion; the difference tests measure code values, so
    /// their fixtures have to enter as code values.
    private func codes(_ level: (Int) -> UInt8) -> CIImage {
        var out: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, side, side,
                            kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]]
                                as CFDictionary, &out)
        guard let out else { fatalError("could not allocate a test frame") }
        CVPixelBufferLockBaseAddress(out, [])
        if let base = CVPixelBufferGetBaseAddress(out) {
            let rowBytes = CVPixelBufferGetBytesPerRow(out)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<side {
                for x in 0..<side {
                    let value = level(x)
                    let pixel = bytes + y * rowBytes + x * 4
                    pixel[0] = value
                    pixel[1] = value
                    pixel[2] = value
                    pixel[3] = 255 // opaque: 32BGRA reads as premultiplied
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(out, [])
        return CIImage(cvPixelBuffer: out, options: [.colorSpace: NSNull()])
    }

    /// A flat gray at an exact 8-bit code (see `codes`).
    private func gray(_ code: UInt8) -> CIImage {
        codes { _ in code }
    }

    /// Identical inputs must come out EXACT black at every gain — the tool
    /// answers "did anything move", and any bias would light up a frame that
    /// matches perfectly. The gain makes this stricter, not looser: a residue
    /// invisible at ×1 is 16 times as visible at ×16.
    @Test func identicalImagesDifferenceToExactBlackAtEveryGain() {
        let image = gray(100)
        for gain in [1.0, 4.0, 16.0] {
            let composed = CompareCompositor.compose(
                front: image, back: image, mode: .difference(gain: gain))
            for (x, y) in [(1, 1), (side / 2, side / 2), (side - 2, side - 2)] {
                let sample = pixel(composed, x: x, y: y)
                #expect(sample.r == 0 && sample.g == 0 && sample.b == 0,
                        "×\(gain) at (\(x),\(y)): \(sample.r)/\(sample.g)/\(sample.b)")
            }
        }
    }

    /// A constructed pair — B is A + 10 codes on the left half and A + 20 on
    /// the right — measured through every gain step. ×1 reads the deltas back
    /// exactly; ×4 multiplies them exactly; ×16 pushes 20 codes past white and
    /// must clamp to 255 while 10 codes (160) still measures, not saturates.
    @Test func differenceMeasuresExactlyAndGainClampsAtTheCeiling() {
        let base = gray(100)
        let other = codes { x in x < side / 2 ? 110 : 120 }

        for (gain, expectLeft, expectRight) in [(1.0, 10, 20), (4.0, 40, 80),
                                                (16.0, 160, 255)] {
            let composed = CompareCompositor.compose(
                front: base, back: other, mode: .difference(gain: gain))
            let l = pixel(composed, x: 4, y: side / 2)
            let r = pixel(composed, x: side - 4, y: side / 2)
            #expect(l.r == expectLeft && l.g == expectLeft && l.b == expectLeft,
                    "×\(gain) left: \(l.r)/\(l.g)/\(l.b), expected \(expectLeft)")
            #expect(r.r == expectRight && r.g == expectRight && r.b == expectRight,
                    "×\(gain) right: \(r.r)/\(r.g)/\(r.b), expected \(expectRight)")
        }
    }

    /// |A−B| has no direction — swapping the halves must not change a single
    /// value, which is what lets every caller ignore which image is "front".
    @Test func differenceIsSymmetric() {
        let one = CompareCompositor.compose(front: gray(100), back: gray(140),
                                            mode: .difference(gain: 1))
        let two = CompareCompositor.compose(front: gray(140), back: gray(100),
                                            mode: .difference(gain: 1))
        let a = pixel(one, x: side / 2, y: side / 2)
        let b = pixel(two, x: side / 2, y: side / 2)
        #expect(a.r == 40 && b.r == 40, "asymmetric: \(a.r) vs \(b.r)")
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
