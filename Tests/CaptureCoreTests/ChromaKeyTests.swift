import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import CaptureCore

/// Frames and readings the chroma-key suites share: a green screen with a
/// subject standing in front of it, and the pixel under a given point.
enum ChromaProbe {
    static let width = 64
    static let height = 32
    /// The subject occupies the middle third; a reading at 0.05 across is
    /// screen, one at 0.5 is subject.
    static let screenX = 0.05
    static let subjectX = 0.5

    /// A BGRA frame: `screen` everywhere, `subject` down the middle.
    static func frame(screen: ChromaKey.RGB, subject: ChromaKey.RGB,
                      width: Int = width, height: Int = height) -> CVPixelBuffer {
        let buffer = TestMedia.pixelBuffer(width: width, height: height)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return buffer }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let subjectRange = (width / 3)..<(2 * width / 3)
        for y in 0..<height {
            let row = bytes + y * rowBytes
            for x in 0..<width {
                let color = subjectRange.contains(x) ? subject : screen
                row[x * 4] = byte(color.blue)
                row[x * 4 + 1] = byte(color.green)
                row[x * 4 + 2] = byte(color.red)
                row[x * 4 + 3] = 255
            }
        }
        return buffer
    }

    static func byte(_ value: Double) -> UInt8 {
        UInt8(min(255, max(0, (value * 255).rounded())))
    }

    /// The same conversion as an Int, for comparing against a read-back pixel.
    static func byteValue(_ value: Double) -> Int { Int(byte(value)) }

    /// A reading off a frame, 0…255 per channel. A named type rather than a
    /// triple, which is both the house rule and the linter's.
    struct Pixel: Equatable, CustomStringConvertible {
        let r: Int
        let g: Int
        let b: Int

        var description: String { "(r: \(r), g: \(g), b: \(b))" }
    }

    /// The pixel at `fraction` across the middle row, in 0…255 per channel.
    static func pixel(of buffer: CVPixelBuffer,
                      atFractionX fraction: Double) -> Pixel {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            return Pixel(r: -1, g: -1, b: -1)
        }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let x = min(width - 1, max(0, Int(Double(width) * fraction)))
        let row = base.assumingMemoryBound(to: UInt8.self) + (height / 2) * rowBytes
        return Pixel(r: Int(row[x * 4 + 2]), g: Int(row[x * 4 + 1]),
                     b: Int(row[x * 4]))
    }

    /// The colors the suites key on and against.
    static let digitalGreen = ChromaKey.RGB(0, 1, 0)
    static let magenta = ChromaKey.RGB(1, 0, 1)
    static let midGray = ChromaKey.RGB(128 / 255.0, 128 / 255.0, 128 / 255.0)
    /// A lit cyc rather than the digital primary — the color a real screen
    /// comes back as, and the reason the eyedropper exists.
    static let litCyc = ChromaKey.RGB(0.24, 0.71, 0.27)
    /// A subject pixel carrying green bounce off that cyc.
    static let spilledEdge = ChromaKey.RGB(120 / 255.0, 170 / 255.0, 120 / 255.0)

    /// A key switched on, with the screen replaced by a flat magenta that no
    /// other color in these frames could be mistaken for.
    static func magentaKey() -> ChromaKey {
        var key = ChromaKey()
        key.isOn = true
        key.background = .color
        key.backgroundColor = magenta
        return key
    }

    /// Push one frame through a pipeline and hand back what reached the screen.
    static func presented(_ pipeline: CapturePipeline, _ buffer: CVPixelBuffer,
                          frame index: Int = 1) async throws -> CVPixelBuffer {
        let collector = PreviewCollector()
        pipeline.setOnDisplayFrame { collector.record($0) }
        defer { pipeline.setOnDisplayFrame(nil) }
        PreviewProbe.push(pipeline, buffer, frame: index)
        await TestWait.until { collector.count > 0 }
        return try #require(collector.last, "nothing was presented")
    }
}

/// The keyer's arithmetic, before any of it reaches a GPU.
///
/// Measured in CHROMA distance throughout, which is the unit the tolerance
/// slider is in: a cyc lit two stops down at the edge of frame is the same
/// distance from the key as the middle of it, and that is the property that
/// makes the one control usable on a real stage.
struct ChromaKeyMathTests {
    @Test func theScreenColorItselfIsFullyKeyedAndASubjectIsNot() {
        let key = ChromaProbe.magentaKey()
        #expect(key.distance(of: ChromaProbe.digitalGreen) == 0)
        #expect(key.matte(for: ChromaProbe.digitalGreen) == 0)
        // mid grey sits 0.6 of chroma away from digital green — nowhere near
        #expect(key.matte(for: ChromaProbe.midGray) == 1)
        #expect(key.distance(of: ChromaProbe.midGray) > 0.5)
    }

    /// The number the whole feature turns on: a real cyc is a THIRD of the
    /// chroma plane away from the digital green a preset can offer, which is
    /// why guessing the color is the problem and the eyedropper is the answer.
    @Test func aLitCycIsFarFromTheDigitalPreset() {
        let key = ChromaProbe.magentaKey()
        let distance = key.distance(of: ChromaProbe.litCyc)
        #expect((0.30...0.36).contains(distance),
                "a lit cyc measured \(distance) from digital green")
        #expect(key.matte(for: ChromaProbe.litCyc) == 1,
                "the default key swallowed a color it was never set to")
    }

    /// Widening the tolerance moves the boundary out past a shade, narrowing it
    /// brings the boundary back in — and the ramp straddles the boundary rather
    /// than hanging off the outside of it.
    @Test func theToleranceMovesTheBoundaryPredictably() {
        var key = ChromaProbe.magentaKey()
        let shade = ChromaProbe.litCyc
        let distance = key.distance(of: shade)

        // clear of the shade by more than half the feather: fully keyed
        key.softness = 0
        key.tolerance = distance + 0.02
        #expect(key.matte(for: shade) == 0, "widening did not reach the shade")

        key.tolerance = distance - 0.02
        #expect(key.matte(for: shade) == 1, "narrowing did not let the shade go")

        // and with the feather back on, the same shade is partly there
        key.softness = 0.5
        let partial = key.matte(for: shade)
        #expect(partial > 0 && partial < 1, "the feather is not ramping: \(partial)")

        // the matte never goes backwards as a color moves away from the screen
        var previous = -1.0
        for step in 0...20 {
            let mix = Double(step) / 20
            let color = ChromaKey.RGB(mix * 0.5, 1 - mix * 0.5, mix * 0.5)
            let matte = key.matte(for: color)
            #expect(matte >= previous, "the matte fell at step \(step)")
            previous = matte
        }
    }

    /// Spill suppression pulls the screen's hue out of the subject and leaves a
    /// color that leans the other way alone.
    @Test func spillSuppressionTakesTheGreenOutOfAnEdgePixel() {
        var key = ChromaProbe.magentaKey()
        key.spill = 0
        #expect(key.suppressed(ChromaProbe.spilledEdge) == ChromaProbe.spilledEdge)

        key.spill = 1
        let cleaned = key.suppressed(ChromaProbe.spilledEdge)
        #expect(cleaned.green < ChromaProbe.spilledEdge.green - 0.02,
                "the green survived the despill: \(cleaned)")
        // luma is preserved: a despilled edge must not go dark
        #expect(abs(ChromaKey.luma(cleaned) - ChromaKey.luma(ChromaProbe.spilledEdge))
                    < 0.01)

        // skin leans away from green and is not touched at all
        let skin = ChromaKey.RGB(0.90, 0.71, 0.59)
        #expect(key.suppressed(skin) == skin)
    }

    /// The lookup table the GPU keys through: the right size, transparent at
    /// the screen color, opaque at the subject, and premultiplied.
    @Test func theCubeCarriesTheMatteInItsAlpha() {
        let key = ChromaProbe.magentaKey()
        let size = ChromaKey.cubeDimension
        let data = key.cubeData(matteOnly: false)
        #expect(data.count == size * size * size * 4 * 4)

        let floats = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        // the lattice point that IS digital green (r=0, g=max, b=0)
        let green = ((0 * size + (size - 1)) * size + 0) * 4
        #expect(floats[green + 3] == 0, "the screen color is not keyed out")
        // premultiplied: a transparent entry carries no color
        #expect(floats[green] == 0 && floats[green + 1] == 0 && floats[green + 2] == 0)
        // white stays opaque white
        let white = (((size - 1) * size + (size - 1)) * size + (size - 1)) * 4
        #expect(floats[white + 3] == 1)
        #expect(floats[white + 1] > 0.99)
    }

    /// The matte view is the same table with the alpha painted into the
    /// picture: black where the screen was, white where the subject is.
    @Test func theMatteCubeIsBlackAndWhite() {
        let key = ChromaProbe.magentaKey()
        let size = ChromaKey.cubeDimension
        let floats = key.cubeData(matteOnly: true)
            .withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let green = ((0 * size + (size - 1)) * size + 0) * 4
        #expect(floats[green] == 0 && floats[green + 3] == 1)
        let white = (((size - 1) * size + (size - 1)) * size + (size - 1)) * 4
        #expect(floats[white] == 1 && floats[white + 3] == 1)
    }

    /// The settings blob stores colors as hex, and a hand-edited one must not
    /// be able to put the keyer outside the range its math is defined on.
    @Test func colorsRoundTripThroughHexAndValuesAreClamped() {
        #expect(ChromaKey.RGB(0, 1, 0).hexString == "#00FF00")
        #expect(ChromaKey.RGB(hex: "#00FF00") == ChromaKey.RGB(0, 1, 0))
        #expect(ChromaKey.RGB(hex: "not a color") == nil)
        #expect(ChromaKey.RGB(hex: "+FF000") == nil)

        var key = ChromaKey()
        key.tolerance = 99
        key.softness = -5
        key.spill = 4
        key.keyColor = ChromaKey.RGB(2, -1, 0.5)
        key.clamp()
        #expect(key.tolerance == ChromaKey.maxTolerance)
        #expect(key.softness == 0)
        #expect(key.spill == 1)
        #expect(key.keyColor == ChromaKey.RGB(1, 0, 0.5))
    }
}

/// The key as the operator sees it: pushed through a real pipeline and read
/// back off the frame that reached the surfaces.
struct ChromaKeyDisplayTests {
    /// The headline case. A green frame with a subject in front of it comes out
    /// with the green replaced and the subject untouched.
    @Test func theScreenBecomesTheBackgroundAndTheSubjectSurvives() async throws {
        let pipeline = PreviewProbe.makePipeline()
        pipeline.setChromaKey(ChromaProbe.magentaKey())
        let source = ChromaProbe.frame(screen: ChromaProbe.digitalGreen,
                                       subject: ChromaProbe.midGray)
        let shown = try await ChromaProbe.presented(pipeline, source)

        let screen = ChromaProbe.pixel(of: shown, atFractionX: ChromaProbe.screenX)
        #expect(screen.r > 250 && screen.g < 5 && screen.b > 250,
                "the screen did not become the background: \(screen)")
        let subject = ChromaProbe.pixel(of: shown, atFractionX: ChromaProbe.subjectX)
        // within a few codes: the cube is a 32³ lattice and the subject sits
        // between its points, so the answer is interpolated rather than exact
        for channel in [subject.r, subject.g, subject.b] {
            #expect(abs(channel - 128) <= 4, "the subject was altered: \(subject)")
        }
    }

    /// Off is off: the very buffer that went in is the one that comes out, so
    /// nothing downstream can be reading a copy that went through a filter.
    @Test func theKeyerOffIsAByteIdenticalPassthrough() async throws {
        let pipeline = PreviewProbe.makePipeline()
        var key = ChromaProbe.magentaKey()
        key.isOn = false
        pipeline.setChromaKey(key)
        let source = ChromaProbe.frame(screen: ChromaProbe.digitalGreen,
                                       subject: ChromaProbe.midGray)
        let shown = try await ChromaProbe.presented(pipeline, source)
        #expect(shown === source, "a switched-off keyer still rendered the frame")
    }

    /// The view a key is actually judged on: alpha as a picture.
    @Test func theMatteViewIsBlackScreenAndWhiteSubject() async throws {
        let pipeline = PreviewProbe.makePipeline()
        var key = ChromaProbe.magentaKey()
        key.background = .matte
        pipeline.setChromaKey(key)
        let shown = try await ChromaProbe.presented(
            pipeline, ChromaProbe.frame(screen: ChromaProbe.digitalGreen,
                                        subject: ChromaProbe.midGray))

        let screen = ChromaProbe.pixel(of: shown, atFractionX: ChromaProbe.screenX)
        #expect(screen.r < 5 && screen.g < 5 && screen.b < 5,
                "the matte is not black over the screen: \(screen)")
        let subject = ChromaProbe.pixel(of: shown, atFractionX: ChromaProbe.subjectX)
        #expect(subject.r > 250 && subject.g > 250 && subject.b > 250,
                "the matte is not white over the subject: \(subject)")
    }

    /// The checkerboard is the default background and it is a PATTERN — two
    /// different grays across the screen area, not one flat fill.
    @Test func theCheckerboardBackgroundIsAPattern() async throws {
        let pipeline = PreviewProbe.makePipeline()
        var key = ChromaProbe.magentaKey()
        key.background = .checkerboard
        pipeline.setChromaKey(key)
        let shown = try await ChromaProbe.presented(
            pipeline, ChromaProbe.frame(screen: ChromaProbe.digitalGreen,
                                        subject: ChromaProbe.midGray))
        // the squares are a 24th of the width, so two readings a few pixels
        // apart along the screen fall in different ones
        let squares = (0..<8).map {
            ChromaProbe.pixel(of: shown, atFractionX: Double($0) * 0.04).r
        }
        #expect(Set(squares).count > 1, "the checkerboard is flat: \(squares)")
        #expect(squares.allSatisfy { $0 > 40 && $0 < 200 },
                "the checkerboard is not the two greys: \(squares)")
    }

    /// Spill suppression reaches the rendered frame, not just the arithmetic.
    @Test func spillSuppressionReachesTheRenderedSubject() async throws {
        let source = ChromaProbe.frame(screen: ChromaProbe.digitalGreen,
                                       subject: ChromaProbe.spilledEdge)
        var clean = ChromaProbe.magentaKey()
        clean.spill = 0
        let pipeline = PreviewProbe.makePipeline()
        pipeline.setChromaKey(clean)
        let untouched = ChromaProbe.pixel(
            of: try await ChromaProbe.presented(pipeline, source, frame: 1),
            atFractionX: ChromaProbe.subjectX)
        #expect(abs(untouched.g - 170) <= 4,
                "spill 0 changed the subject: \(untouched)")

        var despilled = ChromaProbe.magentaKey()
        despilled.spill = 1
        let second = PreviewProbe.makePipeline()
        second.setChromaKey(despilled)
        let cleaned = ChromaProbe.pixel(
            of: try await ChromaProbe.presented(second, source, frame: 1),
            atFractionX: ChromaProbe.subjectX)
        #expect(cleaned.g < untouched.g - 5,
                "the green edge was not despilled: \(cleaned) vs \(untouched)")
    }

    /// Widening the tolerance keys a shade the default leaves alone — through
    /// the whole path, cube rebuild included.
    ///
    /// Spill is off for this one: the despill legitimately desaturates a green
    /// that was NOT keyed, and this test is about the matte's boundary alone.
    @Test func aWiderToleranceKeysTheLitCycTheDefaultLeaves() async throws {
        let source = ChromaProbe.frame(screen: ChromaProbe.litCyc,
                                       subject: ChromaProbe.midGray)
        var narrowKey = ChromaProbe.magentaKey()
        narrowKey.spill = 0
        let narrow = PreviewProbe.makePipeline()
        narrow.setChromaKey(narrowKey)
        let kept = ChromaProbe.pixel(
            of: try await ChromaProbe.presented(narrow, source),
            atFractionX: ChromaProbe.screenX)
        #expect(abs(kept.g - ChromaProbe.byteValue(ChromaProbe.litCyc.green)) <= 4
                    && kept.r < 100,
                "the default tolerance keyed a cyc it should not reach: \(kept)")

        // far enough out that the cyc clears the whole feather, which now
        // straddles the tolerance rather than sitting outside it
        var wide = narrowKey
        wide.tolerance = 0.45
        wide.softness = 0.2
        let widened = PreviewProbe.makePipeline()
        widened.setChromaKey(wide)
        let keyed = ChromaProbe.pixel(
            of: try await ChromaProbe.presented(widened, source),
            atFractionX: ChromaProbe.screenX)
        #expect(keyed.r > 250 && keyed.g < 5,
                "widening the tolerance did not key the cyc: \(keyed)")
    }

    /// The solid background is the color the operator picked, code for code —
    /// which is not free on an unmanaged path (see `ChromaKeyer.passthrough`).
    @Test func theSolidBackgroundIsTheColorItWasGiven() async throws {
        let pipeline = PreviewProbe.makePipeline()
        var key = ChromaProbe.magentaKey()
        key.backgroundColor = ChromaKey.RGB(0.5, 0.5, 0.5)
        pipeline.setChromaKey(key)
        let shown = try await ChromaProbe.presented(
            pipeline, ChromaProbe.frame(screen: ChromaProbe.digitalGreen,
                                        subject: ChromaProbe.midGray))
        let screen = ChromaProbe.pixel(of: shown, atFractionX: ChromaProbe.screenX)
        for channel in [screen.r, screen.g, screen.b] {
            #expect(abs(channel - 128) <= 2,
                    "a 50% grey background rendered as \(screen)")
        }
    }

    /// The eyedropper reads the DISPLAYED frame, and it reads the pixel that is
    /// actually under the point it was given.
    @Test func theEyedropperSamplesTheFrameUnderThePoint() async throws {
        let pipeline = PreviewProbe.makePipeline()
        let source = ChromaProbe.frame(screen: ChromaProbe.litCyc,
                                       subject: ChromaProbe.midGray)
        _ = try await ChromaProbe.presented(pipeline, source)

        let screen = try #require(pipeline.sampleDisplayColor(
            atFractionX: ChromaProbe.screenX, y: 0.5))
        #expect(abs(screen.green - ChromaProbe.litCyc.green) < 0.01,
                "the eyedropper missed the screen: \(screen)")
        let subject = try #require(pipeline.sampleDisplayColor(
            atFractionX: ChromaProbe.subjectX, y: 0.5))
        #expect(abs(subject.green - ChromaProbe.midGray.green) < 0.01,
                "the eyedropper missed the subject: \(subject)")
        // and a pick lands a key that keys exactly what was picked
        var key = ChromaProbe.magentaKey()
        key.keyColor = screen
        #expect(key.matte(for: ChromaProbe.litCyc) == 0)
    }

    /// With no signal there is nothing to pick, and saying so beats handing
    /// back black.
    @Test func theEyedropperHasNothingToSampleWithoutAFrame() {
        let pipeline = PreviewProbe.makePipeline()
        #expect(pipeline.sampleDisplayColor(atFractionX: 0.5, y: 0.5) == nil)
    }
}
