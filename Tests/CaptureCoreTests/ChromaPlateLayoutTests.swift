import CoreGraphics
import CoreVideo
import Foundation
import Testing

@testable import CaptureCore

/// Where the plate lands behind the actor (owner item 37).
///
/// The plate arrives at whatever size the art department made it and the signal
/// is whatever the camera is sending, so "put it in the frame" is three separate
/// decisions — how it is matched to the frame, how far it is pushed in, and
/// where it is slid to. The arithmetic is measured here rather than through a
/// render: a rect is exact, and a pixel off a 32³ cube is not.
struct ChromaPlateLayoutTests {
    /// A 16:9 frame and a 4:3 plate — the mismatch every one of the three fits
    /// answers differently.
    private let frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private let plate = CGSize(width: 1600, height: 1200)

    private func layout(_ fit: ChromaKey.PlateFit = .fit,
                        scale: Double = 1,
                        offsetX: Double = 0,
                        offsetY: Double = 0) -> ChromaKey.PlateLayout {
        var layout = ChromaKey.PlateLayout()
        layout.fit = fit
        layout.scale = scale
        layout.offsetX = offsetX
        layout.offsetY = offsetY
        return layout
    }

    /// Fit puts the whole plate inside the frame, keeping its shape: a 4:3
    /// plate in a 16:9 frame is as tall as the frame and narrower than it.
    @Test func fitPutsTheWholePlateInsideTheFrame() throws {
        let rect = try #require(layout(.fit).rect(forPlate: plate, in: frame))
        #expect(abs(rect.height - 1080) < 0.001)
        #expect(abs(rect.width - 1440) < 0.001, "the plate was not kept at 4:3")
        #expect(frame.insetBy(dx: -0.001, dy: -0.001).contains(rect),
                "fit let the plate out of the frame: \(rect)")
        #expect(abs(rect.midX - frame.midX) < 0.001)
        #expect(abs(rect.midY - frame.midY) < 0.001)
        #expect(!layout(.fit).covers(frame, plate: plate),
                "a fitted 4:3 plate cannot cover a 16:9 frame")
    }

    /// Fill covers the frame, keeping the plate's shape, and lets the overhang
    /// be cropped — which is the point.
    @Test func fillCoversTheFrameAndOverhangs() throws {
        let rect = try #require(layout(.fill).rect(forPlate: plate, in: frame))
        #expect(abs(rect.width - 1920) < 0.001)
        #expect(abs(rect.height - 1440) < 0.001)
        #expect(rect.contains(frame), "fill left a gap: \(rect)")
        #expect(layout(.fill).covers(frame, plate: plate))
        // and the shape is untouched: 4:3 in, 4:3 out
        #expect(abs(rect.width / rect.height - 4.0 / 3) < 0.001)
    }

    /// Stretch is the frame exactly, aspect be damned.
    @Test func stretchIsTheFrameItself() throws {
        let rect = try #require(layout(.stretch).rect(forPlate: plate, in: frame))
        #expect(abs(rect.width - frame.width) < 0.001)
        #expect(abs(rect.height - frame.height) < 0.001)
        #expect(abs(rect.minX - frame.minX) < 0.001)
        #expect(abs(rect.minY - frame.minY) < 0.001)
        #expect(layout(.stretch).covers(frame, plate: plate))
    }

    /// Scale multiplies whichever fit was chosen and keeps the plate centered —
    /// pushing in is a zoom, not a crop from one corner.
    @Test func scaleMultipliesTheFitAroundTheCenter() throws {
        let plain = try #require(layout(.fit).rect(forPlate: plate, in: frame))
        for factor in [0.25, 0.5, 1.5, 2, 4] {
            let scaled = try #require(
                layout(.fit, scale: factor).rect(forPlate: plate, in: frame))
            #expect(abs(scaled.width - plain.width * factor) < 0.001)
            #expect(abs(scaled.height - plain.height * factor) < 0.001)
            #expect(abs(scaled.midX - frame.midX) < 0.001,
                    "×\(factor) moved the plate off centre")
            #expect(abs(scaled.midY - frame.midY) < 0.001)
            // the shape survives the zoom
            #expect(abs(scaled.width / scaled.height
                        - plain.width / plain.height) < 0.001)
        }
        // pushed in far enough, a fitted plate covers the frame after all
        #expect(layout(.fit, scale: 2).covers(frame, plate: plate))
    }

    /// The offset is a fraction of the FRAME, so the slider means the same
    /// distance whatever size the plate is — and positive y raises it, which is
    /// the space the keyer composites in.
    @Test func theOffsetIsAFractionOfTheFrame() throws {
        let centered = try #require(layout(.fill).rect(forPlate: plate, in: frame))
        let right = try #require(
            layout(.fill, offsetX: 0.25).rect(forPlate: plate, in: frame))
        #expect(abs(right.midX - centered.midX - frame.width * 0.25) < 0.001)
        #expect(abs(right.midY - centered.midY) < 0.001)

        let up = try #require(
            layout(.fill, offsetY: 0.1).rect(forPlate: plate, in: frame))
        #expect(abs(up.midY - centered.midY - frame.height * 0.1) < 0.001,
                "a positive y offset did not raise the plate")

        // the same fraction on a plate half the size moves it just as far
        let small = CGSize(width: 800, height: 600)
        let smallCentered = try #require(
            layout(.fill).rect(forPlate: small, in: frame))
        let smallRight = try #require(
            layout(.fill, offsetX: 0.25).rect(forPlate: small, in: frame))
        #expect(abs(smallRight.midX - smallCentered.midX
                    - frame.width * 0.25) < 0.001)
    }

    /// Fit, scale and offset compose in that order, and the result is what a
    /// reader of the three controls would predict.
    @Test func theThreeControlsCompose() throws {
        let rect = try #require(layout(.fit, scale: 1.5, offsetX: -0.1,
                                       offsetY: 0.2)
            .rect(forPlate: plate, in: frame))
        #expect(abs(rect.width - 1440 * 1.5) < 0.001)
        #expect(abs(rect.height - 1080 * 1.5) < 0.001)
        #expect(abs(rect.midX - (frame.midX - 192)) < 0.001)
        #expect(abs(rect.midY - (frame.midY + 216)) < 0.001)
    }

    /// A frame whose origin is not zero — which is what a cropped CIImage
    /// extent is — places against that origin rather than against zero.
    @Test func aFrameAwayFromTheOriginIsRespected() throws {
        let shifted = CGRect(x: 120, y: 40, width: 1920, height: 1080)
        let rect = try #require(layout(.stretch).rect(forPlate: plate,
                                                      in: shifted))
        #expect(abs(rect.minX - 120) < 0.001)
        #expect(abs(rect.minY - 40) < 0.001)
    }

    /// Nothing to place is nil, not a rect of zeros: the keyer shows the
    /// checkerboard on nil and would divide by zero on the alternative.
    @Test func aDegeneratePlateOrFrameHasNoPlacement() {
        #expect(layout().rect(forPlate: .zero, in: frame) == nil)
        #expect(layout().rect(forPlate: plate, in: .zero) == nil)
        #expect(layout().rect(forPlate: CGSize(width: 100, height: 0),
                              in: frame) == nil)
        #expect(!layout().covers(.zero, plate: plate))
    }

    /// A hand-edited settings blob cannot put the plate somewhere the sliders
    /// could not reach, or scale it to nothing.
    @Test func theLayoutIsClamped() {
        var wild = layout(.fill, scale: 99, offsetX: 12, offsetY: -7)
        wild.clamp()
        #expect(wild.scale == ChromaKey.PlateLayout.maxScale)
        #expect(wild.offsetX == ChromaKey.PlateLayout.maxOffset)
        #expect(wild.offsetY == -ChromaKey.PlateLayout.maxOffset)

        var tiny = layout(scale: 0)
        tiny.clamp()
        #expect(tiny.scale == ChromaKey.PlateLayout.minScale)

        // and the key clamps it along with everything else it owns
        var key = ChromaKey()
        key.plate.scale = 500
        key.clamp()
        #expect(key.plate.scale == ChromaKey.PlateLayout.maxScale)
        #expect(ChromaKey().plate == ChromaKey.PlateLayout.identity,
                "a fresh key does not start on a plain centered fit")
    }
}

/// The plate as it reaches the screen: the layout the panel dials in is the
/// layout the keyer composites.
struct ChromaPlateRenderTests {
    /// The frame the key eats entirely, so the plate is all that is left.
    private static func greenFrame(width: Int, height: Int) -> CVPixelBuffer {
        ChromaProbe.frame(screen: ChromaProbe.digitalGreen,
                          subject: ChromaProbe.digitalGreen,
                          width: width, height: height)
    }

    /// A plate: red left, blue right.
    private static func plate() -> CVPixelBuffer {
        let size = 32
        let buffer = TestMedia.pixelBuffer(width: size, height: size)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return buffer }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<size {
            let row = bytes + y * rowBytes
            for x in 0..<size {
                let red = x < size / 2
                row[x * 4] = red ? 0 : 255      // B
                row[x * 4 + 1] = 0              // G
                row[x * 4 + 2] = red ? 255 : 0  // R
                row[x * 4 + 3] = 255
            }
        }
        return buffer
    }

    /// What is at a fraction across the middle row: "black", "red", "blue".
    private func band(_ buffer: CVPixelBuffer, at fraction: Double) -> String {
        Self.name(ChromaProbe.pixel(of: buffer, atFractionX: fraction))
    }

    /// The same reading on a named ROW, counted from the top. `ChromaProbe`
    /// only ever reads the middle one, and the middle one cannot see a bar
    /// above or below the plate.
    private func band(_ buffer: CVPixelBuffer, at fraction: Double,
                      row rowIndex: Int) -> String {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return "none" }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let x = min(width - 1, max(0, Int(Double(width) * fraction)))
        let row = base.assumingMemoryBound(to: UInt8.self)
            + min(height - 1, max(0, rowIndex)) * rowBytes
        return Self.name(ChromaProbe.Pixel(r: Int(row[x * 4 + 2]),
                                           g: Int(row[x * 4 + 1]),
                                           b: Int(row[x * 4])))
    }

    private static func name(_ pixel: ChromaProbe.Pixel) -> String {
        if pixel.r > 200 && pixel.b < 60 { return "red" }
        if pixel.b > 200 && pixel.r < 60 { return "blue" }
        if pixel.r < 40 && pixel.g < 40 && pixel.b < 40 { return "black" }
        return "other \(pixel)"
    }

    private func rendered(_ layout: ChromaKey.PlateLayout) async throws
        -> CVPixelBuffer {
        var key = ChromaProbe.magentaKey()
        key.background = .image
        key.plate = layout
        let pipeline = PreviewProbe.makePipeline()
        pipeline.setChromaKey(key)
        pipeline.setChromaBackgroundImage(Self.plate())
        return try await ChromaProbe.presented(
            pipeline, Self.greenFrame(width: 64, height: 32))
    }

    /// Fit letterboxes the square plate in a 2:1 frame: black either side, the
    /// plate's own seam dead centre.
    @Test func aFittedPlateIsLetterboxedAndCentered() async throws {
        var layout = ChromaKey.PlateLayout()
        layout.fit = .fit
        let shown = try await rendered(layout)
        #expect(band(shown, at: 0.05) == "black", "fit did not letterbox")
        #expect(band(shown, at: 0.95) == "black")
        #expect(band(shown, at: 0.35) == "red")
        #expect(band(shown, at: 0.65) == "blue")
    }

    /// Fill covers the frame: no black anywhere, and the seam still in the
    /// middle because the overhang is cropped evenly.
    @Test func aFilledPlateReachesBothEdges() async throws {
        var layout = ChromaKey.PlateLayout()
        layout.fit = .fill
        let shown = try await rendered(layout)
        #expect(band(shown, at: 0.02) == "red", "fill left a gap on the left")
        #expect(band(shown, at: 0.98) == "blue", "fill left a gap on the right")
        #expect(band(shown, at: 0.35) == "red")
        #expect(band(shown, at: 0.65) == "blue")
    }

    /// The letterbox is on all four sides, not just left and right.
    ///
    /// A plate pushed in to half size leaves a bar above and below it as well,
    /// and nothing else in this suite reads a row other than the middle one —
    /// so nothing else would notice the top and bottom bars going the way the
    /// left and right ones did on a macOS 15 runner: filled with the plate's
    /// own edge row instead of with black, because an image composited over a
    /// colour states where it stops with its extent and with nothing in its
    /// pixels (see `CIImage.letterboxed(in:with:)`).
    @Test func aPlatePushedInIsLetterboxedOnAllFourSides() async throws {
        var layout = ChromaKey.PlateLayout()
        layout.fit = .fit
        layout.scale = 0.5
        let shown = try await rendered(layout)
        // fitted the square plate is the frame's full height; at half scale it
        // is the middle 16x16 of a 64x32 frame, with its seam still centred
        #expect(band(shown, at: 0.42) == "red")
        #expect(band(shown, at: 0.58) == "blue")
        #expect(band(shown, at: 0.05) == "black")
        #expect(band(shown, at: 0.95) == "black")
        #expect(band(shown, at: 0.42, row: 2) == "black",
                "the plate's top row was smeared into the bar above it")
        #expect(band(shown, at: 0.58, row: 29) == "black",
                "the plate's bottom row was smeared into the bar below it")
    }

    /// And the offset slides it: a quarter of a frame to the right puts the
    /// fitted plate's black gap all on the left.
    @Test func theOffsetMovesThePlateOnScreen() async throws {
        var layout = ChromaKey.PlateLayout()
        layout.fit = .fit
        layout.offsetX = 0.25
        let shown = try await rendered(layout)
        #expect(band(shown, at: 0.05) == "black")
        #expect(band(shown, at: 0.35) == "black",
                "the plate did not move right")
        #expect(band(shown, at: 0.6) == "red")
        #expect(band(shown, at: 0.9) == "blue")
    }
}
