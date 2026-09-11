import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import CaptureCore

/// **The gamut conversion in the PICTURE, not only in the tag.**
///
/// `DailiesToneMapTests` pins what a proxy says about itself — 1-1-1, for
/// every source there is. That claim is only true because the composer
/// converts the codes, and a tag is exactly the kind of thing that goes on
/// being written after the work behind it stops happening: a file saying 709
/// over Rec.2020 codes is the desaturated-against-correct mismatch this app
/// has already been bitten by once, and nothing on screen would say why.
///
/// So this suite measures the composer's OUTPUT for a wide-gamut source, as
/// codes, against the arithmetic.
@Suite struct DailiesGamutTests {
    private struct Codes {
        let r: Double, g: Double, b: Double
    }

    /// A flat BGRA frame at one colour — the composer's input.
    private func frame(_ codes: Codes, width: Int = 64,
                       height: Int = 32) -> CVPixelBuffer {
        let buffer = TestMedia.pixelBuffer(width: width, height: height)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return buffer }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            let row = bytes + y * rowBytes
            for x in 0..<width {
                row[x * 4] = UInt8((codes.b * 255).rounded())
                row[x * 4 + 1] = UInt8((codes.g * 255).rounded())
                row[x * 4 + 2] = UInt8((codes.r * 255).rounded())
                row[x * 4 + 3] = 255
            }
        }
        return buffer
    }

    private func centre(of buffer: CVPixelBuffer) -> Codes {
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

    /// The conversion computed straight, with no cube and no CoreImage in it.
    private func converted(_ codes: Codes) throws -> Codes {
        let inverse = try #require(ColorPrimaries.rec709.rgbToXYZ.inverse)
        let light = LinearRGB(r: CubeLUT.linearized(codes.r),
                              g: CubeLUT.linearized(codes.g),
                              b: CubeLUT.linearized(codes.b))
        let out = inverse.linearRGB(
            ColorPrimaries.rec2020.rgbToXYZ.tristimulus(light))
        return Codes(r: CubeLUT.encoded(out.r), g: CubeLUT.encoded(out.g),
                     b: CubeLUT.encoded(out.b))
    }

    /// **A wide-gamut frame comes out of the composer on Rec.709 primaries.**
    ///
    /// Through the composer rather than through the cube on its own, because
    /// what this is checking is the WIRING: that the stage is built for a
    /// source whose colorimetry says 2020, that it runs on the picture, and
    /// that it runs after the tone map's lookup rather than instead of it.
    /// The frame is a saturated orange — neutral would pass this test with the
    /// stage deleted, since D65 is D65 in both spaces, which is why the
    /// neutral is a test of its own below and not this one.
    @Test func theComposerPutsAWideGamutFrameOnRec709() async throws {
        let root = try DailiesRig.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await DailiesRig.writeHDRTake(
            at: root.appendingPathComponent("hdr.mov"), transfer: .pq,
            nits: HDRTransfer.referenceWhiteNits, width: 320, height: 180,
            frames: 4)
        let item = DailiesRig.item(for: source)
        let facts = try await DailiesSourceFacts.probe(
            item: item, burnins: DailiesRig.noBurnins)
        #expect(facts.colorimetry.exceedsRec709,
                "the fixture is not a wide-gamut source: \(facts.colorimetry)")
        let composer = try DailiesFrameComposer(item: item,
                                                burnins: DailiesRig.noBurnins,
                                                facts: facts)

        // Dark enough that the tone map's own lookup does not park red on
        // white before the conversion gets to it — a clipped channel cannot
        // show that anything happened to it.
        let input = Codes(r: 96 / 255, g: 48 / 255, b: 36 / 255)
        let composed = try composer.compose(frame(input), pts: .zero)
        let shown = centre(of: composed)

        // The picture's own lookup runs FIRST (`compose` — the levels table,
        // which for a PQ source is the tone map), so the expected answer is
        // the conversion of what that lookup leaves behind, not of what went
        // in. Stating it this way is what keeps this a test of the gamut
        // stage rather than of the order of the two.
        let table = try #require(facts.levels, "a PQ source has no lookup")
        let levelled = Codes(
            r: Double(table[Int((input.r * 255).rounded())]) / 255,
            g: Double(table[Int((input.g * 255).rounded())]) / 255,
            b: Double(table[Int((input.b * 255).rounded())]) / 255)
        let want = try converted(levelled)
        let error = max(abs(want.r - shown.r),
                        max(abs(want.g - shown.g), abs(want.b - shown.b)))
        #expect(error < 3 / 255.0, """
            the composer produced \(shown.r) \(shown.g) \(shown.b) where the \
            conversion of the tone-mapped frame is \(want.r) \(want.g) \(want.b)
            """)
        // …and it is not simply the tone-mapped frame handed back: a saturated
        // colour needs MORE of Rec.709's narrower red, and less of the rest.
        #expect(shown.r > levelled.r + 0.01, """
            red came back at \(shown.r) against \(levelled.r) before the \
            conversion — nothing converted it
            """)
        #expect(shown.b < levelled.b - 0.005, """
            blue came back at \(shown.b) against \(levelled.b) — nothing \
            converted it
            """)
    }

    /// **Neutral survives it**, which is the other half and the one an
    /// operator sees: a grey card, a white slate, a face lit neutral. Rec.709
    /// and Rec.2020 share D65, so the conversion has nothing to do here — and
    /// a matrix built wrong shows up as a grey with a cast in every daily.
    @Test func aNeutralFrameComesThroughTheConversionNeutral() async throws {
        let root = try DailiesRig.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await DailiesRig.writeHDRTake(
            at: root.appendingPathComponent("hdr.mov"), transfer: .pq,
            nits: HDRTransfer.referenceWhiteNits, width: 320, height: 180,
            frames: 4)
        let item = DailiesRig.item(for: source)
        let facts = try await DailiesSourceFacts.probe(
            item: item, burnins: DailiesRig.noBurnins)
        let composer = try DailiesFrameComposer(item: item,
                                                burnins: DailiesRig.noBurnins,
                                                facts: facts)
        let grey = Codes(r: 160 / 255, g: 160 / 255, b: 160 / 255)
        let shown = centre(of: try composer.compose(frame(grey), pts: .zero))
        let cast = max(abs(shown.r - shown.g), abs(shown.g - shown.b))
        #expect(cast <= 1 / 255.0, """
            a neutral frame came out \(shown.r) \(shown.g) \(shown.b) — the \
            conversion put a cast on grey
            """)
    }
}
