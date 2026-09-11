import CoreImage
import CoreVideo
import Foundation
import Testing

@testable import CaptureCore

/// **The gamut conversion, measured** — `CubeLUT.gamut`.
///
/// A daily made from a wide-gamut take used to carry the camera's own codes
/// and state Rec.2020 primaries, which is honest and is not what most things
/// that open a proxy do anything with (owner: "ток теги 1-1-1 полюбас должны
/// быть"). The picture is put on Rec.709 now, and these are the numbers that
/// say it is the same picture: neutral unmoved, in-gamut colour unmoved in
/// chromaticity, out-of-gamut colour on the boundary and not somewhere else.
@Suite struct GamutCubeTests {
    /// One lattice entry, as the three codes it holds.
    private struct Codes {
        let r: Double, g: Double, b: Double
    }

    private func floats(of cube: CubeLUT) -> [Float] {
        cube.data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
    }

    /// Red fastest, then green, then blue — the order the cube is written in.
    private func entry(_ values: [Float], size: Int,
                       _ red: Int, _ green: Int, _ blue: Int) -> Codes {
        let index = ((blue * size + green) * size + red) * 4
        return Codes(r: Double(values[index]), g: Double(values[index + 1]),
                     b: Double(values[index + 2]))
    }

    /// The conversion, computed straight — what the cube is an approximation
    /// of, and what every assertion here is against.
    private func exact(_ codes: Codes, from source: ColorPrimaries,
                       to target: ColorPrimaries) throws -> Codes {
        let inverse = try #require(target.rgbToXYZ.inverse)
        let light = LinearRGB(r: CubeLUT.linearized(codes.r),
                              g: CubeLUT.linearized(codes.g),
                              b: CubeLUT.linearized(codes.b))
        let converted = inverse.linearRGB(source.rgbToXYZ.tristimulus(light))
        return Codes(r: CubeLUT.encoded(converted.r),
                     g: CubeLUT.encoded(converted.g),
                     b: CubeLUT.encoded(converted.b))
    }

    /// The chromaticity a code triple stands for under one set of primaries —
    /// the question the whole conversion is about, since a gamut change is
    /// exactly a change in what a triple MEANS.
    private func chromaticity(of codes: Codes,
                              under primaries: ColorPrimaries) -> Chromaticity? {
        primaries.rgbToXYZ.chromaticity(r: CubeLUT.linearized(codes.r),
                                        g: CubeLUT.linearized(codes.g),
                                        b: CubeLUT.linearized(codes.b))
    }

    /// **Neutral does not move, at all.**
    ///
    /// Rec.709 and Rec.2020 share CIE D65, so R = G = B is the same colour in
    /// both and the conversion has nothing to do to it. It is the assertion
    /// worth making first because it is the one an operator sees: a grey card,
    /// a white slate, a face lit neutral. A matrix built with its primaries
    /// unscaled — the classic mistake this derivation exists to avoid — fails
    /// here and nowhere else.
    @Test func neutralIsUntouchedByTheConversion() throws {
        let size = 33
        let cube = try #require(CubeLUT.gamut(from: .rec2020, to: .rec709,
                                              size: size))
        let values = floats(of: cube)
        var worst = 0.0
        for step in 0..<size {
            let codes = entry(values, size: size, step, step, step)
            let expected = Double(step) / Double(size - 1)
            worst = max(worst, abs(codes.r - expected))
            worst = max(worst, abs(codes.g - expected))
            worst = max(worst, abs(codes.b - expected))
        }
        #expect(worst < 1e-5, "a neutral ramp moved by \(worst) of full scale")
    }

    /// **A primary lands on the corner**, which is the clip doing its job.
    ///
    /// Rec.2020's red is outside Rec.709 — that is what "wider" means — so
    /// there is no Rec.709 triple for it and the honest answer is the reddest
    /// one there is. What must NOT happen is the arithmetic leaking out: a
    /// negative component encoded as a `pow` of a negative is NaN, and a NaN
    /// in a cube is a black hole in the picture wherever it is indexed.
    @Test func theWideGamutPrimariesLandOnTheRec709Corners() throws {
        let size = 33
        let cube = try #require(CubeLUT.gamut(from: .rec2020, to: .rec709,
                                              size: size))
        let values = floats(of: cube)
        let red = entry(values, size: size, size - 1, 0, 0)
        #expect(red.r == 1 && red.g == 0 && red.b == 0,
                "Rec.2020 red came out \(red.r) \(red.g) \(red.b)")
        let green = entry(values, size: size, 0, size - 1, 0)
        #expect(green.r == 0 && green.g == 1 && green.b == 0,
                "Rec.2020 green came out \(green.r) \(green.g) \(green.b)")
        // Every entry is a number: the clip is what guarantees it.
        let bad = values.filter { !$0.isFinite }.count
        #expect(bad == 0, "\(bad) cube entries are not finite")
    }

    /// **An in-gamut colour keeps its chromaticity.** The conversion changes
    /// the CODES and must not change the colour: that is the whole contract,
    /// and it is the one thing a matrix written the wrong way round would
    /// still look plausible without.
    @Test func anInGamutColourKeepsItsChromaticity() throws {
        let size = 33
        let cube = try #require(CubeLUT.gamut(from: .rec2020, to: .rec709,
                                              size: size))
        let values = floats(of: cube)
        var checked = 0
        var worst = 0.0
        for red in stride(from: 4, to: size, by: 4) {
            for green in stride(from: 4, to: size, by: 4) {
                for blue in stride(from: 4, to: size, by: 4) {
                    let last = Double(size - 1)
                    let source = Codes(r: Double(red) / last,
                                       g: Double(green) / last,
                                       b: Double(blue) / last)
                    let result = entry(values, size: size, red, green, blue)
                    // A clipped entry is a colour Rec.709 cannot hold, and its
                    // chromaticity is SUPPOSED to have moved — it is on the
                    // boundary now. Those are the next test's business.
                    guard result.r > 0, result.g > 0, result.b > 0,
                          result.r < 1, result.g < 1, result.b < 1,
                          let want = chromaticity(of: source, under: .rec2020),
                          let got = chromaticity(of: result, under: .rec709)
                    else { continue }
                    checked += 1
                    worst = max(worst, max(abs(want.x - got.x),
                                           abs(want.y - got.y)))
                }
            }
        }
        #expect(checked > 100, "only \(checked) in-gamut lattice points tested")
        #expect(worst < 1e-6, """
            an in-gamut colour's chromaticity moved by \(worst) — the codes are \
            supposed to change and the colour is not
            """)
    }

    /// **What the lattice costs**, between the points rather than on them.
    ///
    /// On a lattice point the cube IS the exact conversion by construction, so
    /// the only error a size can have is what trilinear interpolation does
    /// between eight of them. The function it interpolates is a matrix in
    /// LIGHT indexed by CODES, and the re-encode has an infinite slope at
    /// zero: over most of the cube that is nothing at all, and on a saturated
    /// colour with a channel near black it is the whole error. So this
    /// measures the DISTRIBUTION and not a single number — a worst case that
    /// lands on one corner of colour space says nothing about the picture.
    ///
    /// CIE xy error over a 17³ grid placed deliberately BETWEEN lattice
    /// points, counting colours whose codes are all above 10 % (below that a
    /// colour's chromaticity is the black of a picture and nothing anyone
    /// judges), on this machine:
    ///
    /// | | worst | p99 | median | built |
    /// | --- | --- | --- | --- | --- |
    /// | 33³ | 0.0073 | 0.0033 | 0.00019 | 9.5 ms |
    /// | 65³ | 0.0030 | 0.0010 | 0.00004 | 69 ms |
    ///
    /// A vectorscope target box is about 0.02 across in xy: the typical colour
    /// is untouched by either lattice and the tail is what separates them.
    /// 65³ is what ships — 60 ms and 4.4 MB once per CLIP against a transcode
    /// measured in seconds, for a third of the tail.
    @Test func theLatticeIsFineEnough() throws {
        let shipped = try #require(CubeLUT.gamut(from: .rec2020, to: .rec709))
        #expect(shipped.size == CubeLUT.gamutLattice)
        let coarse = try #require(CubeLUT.gamut(from: .rec2020, to: .rec709,
                                                size: 33))
        let error = try latticeError(of: shipped)
        let coarseError = try latticeError(of: coarse)
        print("gamut cube xy error — \(shipped.size)³ worst \(error.worst) "
            + "p99 \(error.p99) median \(error.median); 33³ worst "
            + "\(coarseError.worst) p99 \(coarseError.p99) median "
            + "\(coarseError.median)")
        #expect(error.median < 0.0002, """
            the typical colour moves \(error.median) in xy through the cube \
            that is supposed to be leaving it where it is
            """)
        #expect(error.p99 < 0.002, """
            a hundredth of the colours move more than \(error.p99) in xy — a \
            tenth of a vectorscope box is where this stops being a rounding
            """)
        #expect(error.worst < 0.005, """
            the worst colour moves \(error.worst) in xy, against 0.02 for a \
            whole target box
            """)
        // …and the shipped lattice is the one that earns its size.
        #expect(error.worst < coarseError.worst, """
            \(shipped.size)³ is no better than 33³ at the tail \
            (\(error.worst) against \(coarseError.worst)) — then it is eight \
            times the build for nothing
            """)
    }

    /// One cube's interpolation error, as a distribution — see
    /// `theLatticeIsFineEnough` for why a single number would mislead.
    private struct LatticeError {
        var worst = 0.0
        var p99 = 0.0
        var median = 0.0
    }

    /// The chromaticity error an in-gamut colour picks up from the
    /// interpolation, over a grid deliberately OFF the lattice.
    private func latticeError(of cube: CubeLUT) throws -> LatticeError {
        let values = floats(of: cube)
        var errors: [Double] = []
        let steps = 17
        for red in 0..<steps {
            for green in 0..<steps {
                for blue in 0..<steps {
                    let codes = Codes(r: (Double(red) + 0.5) / Double(steps),
                                      g: (Double(green) + 0.5) / Double(steps),
                                      b: (Double(blue) + 0.5) / Double(steps))
                    // Above the floor, and a colour Rec.709 can hold at all:
                    // being wrong about one it cannot is the CLIP, which is a
                    // decision and not an error.
                    let straight = try exact(codes, from: .rec2020, to: .rec709)
                    guard codes.r > 0.1, codes.g > 0.1, codes.b > 0.1,
                          straight.r > 0.02, straight.g > 0.02, straight.b > 0.02,
                          straight.r < 0.98, straight.g < 0.98, straight.b < 0.98,
                          let want = chromaticity(of: codes, under: .rec2020),
                          let got = chromaticity(of: sample(values,
                                                            size: cube.size,
                                                            at: codes),
                                                 under: .rec709)
                    else { continue }
                    errors.append(max(abs(want.x - got.x), abs(want.y - got.y)))
                }
            }
        }
        let sorted = errors.sorted()
        guard let worst = sorted.last else { return LatticeError() }
        return LatticeError(worst: worst,
                            p99: sorted[Int(Double(sorted.count) * 0.99)],
                            median: sorted[sorted.count / 2])
    }

    /// Trilinear, the way a GPU samples a 3D texture — the arithmetic
    /// `CIColorCube` does, restated here so "what the cube answers between its
    /// points" is a number this suite can hold.
    private func sample(_ values: [Float], size: Int, at codes: Codes) -> Codes {
        let last = Double(size - 1)
        let position = [codes.r, codes.g, codes.b].map {
            min(last, max(0, $0 * last))
        }
        let low = position.map { Int($0.rounded(.down)) }
        let high = low.map { min($0 + 1, size - 1) }
        let fraction = zip(position, low).map { $0 - Double($1) }
        var out = [0.0, 0.0, 0.0]
        for corner in 0..<8 {
            let red = corner & 1 == 0 ? low[0] : high[0]
            let green = corner & 2 == 0 ? low[1] : high[1]
            let blue = corner & 4 == 0 ? low[2] : high[2]
            let weight = (corner & 1 == 0 ? 1 - fraction[0] : fraction[0])
                * (corner & 2 == 0 ? 1 - fraction[1] : fraction[1])
                * (corner & 4 == 0 ? 1 - fraction[2] : fraction[2])
            guard weight > 0 else { continue }
            let held = entry(values, size: size, red, green, blue)
            out[0] += weight * held.r
            out[1] += weight * held.g
            out[2] += weight * held.b
        }
        return Codes(r: out[0], g: out[1], b: out[2])
    }

    /// **The filter applies it to the CODE values**, which is the assumption
    /// the whole cube rests on: a `.cube` is defined on gamma-encoded codes,
    /// and every path in this app renders one with colour management off. If
    /// `CIColorCubeWithColorSpace` were converting into a working space before
    /// indexing, the rendered frame would be nowhere near this.
    @Test func theRenderedFrameMatchesTheArithmetic() throws {
        let cube = try #require(CubeLUT.gamut(from: .rec2020, to: .rec709))
        let filter = try #require(cube.makeCodeFilter())
        let source = Codes(r: 204 / 255, g: 102 / 255, b: 76 / 255)
        let frame = PreviewProbe.frame(0)
        fill(frame, with: source)
        let input = CIImage(cvPixelBuffer: frame, options: [.colorSpace: NSNull()])
        filter.setValue(input, forKey: kCIInputImageKey)
        let output = try #require(filter.outputImage)
        let rendered = try #require(render(output, like: frame))

        let want = try exact(source, from: .rec2020, to: .rec709)
        let got = read(rendered)
        let error = max(abs(want.r - got.r), max(abs(want.g - got.g),
                                                 abs(want.b - got.b)))
        #expect(error < 3 / 255.0, """
            the filter produced \(got.r) \(got.g) \(got.b) where the \
            conversion is \(want.r) \(want.g) \(want.b)
            """)
        // …and it really did something: a saturated Rec.2020 colour needs MORE
        // of a narrower primary, so red goes up and the other two come down.
        #expect(got.r > source.r + 0.01 && got.b < source.b - 0.01, """
            the frame came back at \(got.r) \(got.g) \(got.b) — that is the \
            colour that went in
            """)
    }
}

/// The CoreImage end of the suite: a frame in, a frame out, code values
/// both ways. Split into an extension only because the suite reached the
/// type-body ceiling — same tests, same file.
extension GamutCubeTests {
    private func fill(_ buffer: CVPixelBuffer, with codes: Codes) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let width = CVPixelBufferGetWidth(buffer)
        for y in 0..<CVPixelBufferGetHeight(buffer) {
            let row = bytes + y * rowBytes
            for x in 0..<width {
                row[x * 4] = UInt8((codes.b * 255).rounded())
                row[x * 4 + 1] = UInt8((codes.g * 255).rounded())
                row[x * 4 + 2] = UInt8((codes.r * 255).rounded())
                row[x * 4 + 3] = 255
            }
        }
    }

    private func read(_ buffer: CVPixelBuffer) -> Codes {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            return Codes(r: -1, g: -1, b: -1)
        }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let row = bytes + (CVPixelBufferGetHeight(buffer) / 2)
            * CVPixelBufferGetBytesPerRow(buffer)
        let x = CVPixelBufferGetWidth(buffer) / 2
        return Codes(r: Double(row[x * 4 + 2]) / 255,
                     g: Double(row[x * 4 + 1]) / 255,
                     b: Double(row[x * 4]) / 255)
    }

    /// Raw codes in and raw codes out — `destination.colorSpace = nil`, the
    /// way the dailies composer renders its own cube stage.
    private func render(_ image: CIImage,
                        like frame: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(frame)
        let height = CVPixelBufferGetHeight(frame)
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_32BGRA, attrs as CFDictionary,
                            &buffer)
        guard let buffer else { return nil }
        let destination = CIRenderDestination(pixelBuffer: buffer)
        destination.colorSpace = nil
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let task = try? context.startTask(toRender: image,
                                                to: destination),
              (try? task.waitUntilCompleted()) != nil else { return nil }
        return buffer
    }
}
