import CoreVideo
import Foundation
import Testing

@testable import CaptureCore

/// The `'R12B'` bit layout, pinned against Blackmagic's published byte table.
///
/// `R12BPacking` implements the format as a one-sentence rule (nine big-endian
/// words, components at 12-bit offsets into their little-endian concatenation);
/// `R12BFixtures` writes frames from the table field by field. These tests hold
/// the two to each other. Nothing here needs a board — which is the point,
/// because there isn't one, and a packing mistake on set costs a shooting day.
struct R12BPackingTests {
    /// Distinct, non-symmetric values for all 24 components of a block, so a
    /// swapped pair or a shifted nibble cannot pass. Every one of them uses
    /// bits in both halves of its 12.
    private static let distinctComponents: [Int] =
        (0..<24).map { ($0 * 0x0A7 + 0x123) & 0xFFF }

    @Test func coreVideoKnowsTheFormatWithoutRegistration() throws {
        // 'R12B' is described by CoreVideo itself (288 bits per 8-pixel block),
        // so the capture pool needs no
        // CVPixelFormatDescriptionRegisterDescriptionWithPixelFormatType call.
        // If that ever stops being true, buffers come out with a nonsense
        // stride and this is where it shows.
        let description = CVPixelFormatDescriptionCreateWithPixelFormatType(
            kCFAllocatorDefault, R12BPacking.pixelFormat) as? [CFString: Any]
        let known = try #require(description, "CoreVideo does not know 'R12B'")
        #expect(known[kCVPixelFormatBitsPerBlock] as? Int == 288)
        #expect(known[kCVPixelFormatBlockWidth] as? Int == 8)
    }

    /// The rule and the published table agree on every component of a block —
    /// including the six that straddle a word boundary.
    @Test func everyComponentOfABlockMatchesThePublishedTable() {
        let packed = R12BFixtures.packBlock(Self.distinctComponents)
        packed.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            for k in 0..<R12BPacking.blockComponents {
                let got = R12BPacking.component(base, k)
                let want = Self.distinctComponents[k]
                #expect(got == want,
                        "component \(k): rule gave \(got), table says \(want)")
            }
        }
    }

    /// The six components that cross a 32-bit word boundary, called out on
    /// their own: these are the ones a per-word unpack gets wrong, and a test
    /// that only checked pixel 0 would never touch four of them.
    @Test func theComponentsThatStraddleAWordBoundaryAreExact() {
        // B0, B1, G3, G4, R6, R7 — see R12BFixtures.byteTable
        let straddling = [2, 5, 10, 13, 18, 21]
        // all-ones in one component at a time: a borrowed or dropped nibble
        // shows up as 0x0FF / 0xF00 instead of 0xFFF
        for k in straddling {
            var components = [Int](repeating: 0, count: R12BPacking.blockComponents)
            components[k] = 0xFFF
            let packed = R12BFixtures.packBlock(components)
            packed.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                for probe in 0..<R12BPacking.blockComponents {
                    let expected = probe == k ? 0xFFF : 0
                    let got = R12BPacking.component(base, probe)
                    #expect(got == expected,
                            "only \(k) set: component \(probe) read \(got)")
                }
            }
        }
    }

    /// The sequential unpack (nine loads) and the random-access one (up to two
    /// loads per component) are the same function. They are separate code, and
    /// the converter uses one while the scopes use the other.
    @Test func theSequentialAndRandomAccessFormsAgree() {
        let packed = R12BFixtures.packBlock(Self.distinctComponents)
        packed.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var out = [UInt16](repeating: 0, count: R12BPacking.blockComponents)
            out.withUnsafeMutableBufferPointer { buffer in
                guard let target = buffer.baseAddress else { return }
                R12BPacking.unpackBlock(base, into: target)
            }
            for k in 0..<R12BPacking.blockComponents {
                let random = R12BPacking.component(base, k)
                #expect(Int(out[k]) == random,
                        "component \(k): block \(out[k]) vs random \(random)")
            }
        }
    }

    /// A whole frame, read back through the per-pixel accessor the scopes use.
    /// Two blocks wide so the second block's base offset is exercised, and the
    /// values vary with x AND y so a row-stride mistake cannot pass.
    @Test func aFrameRoundTripsThroughThePixelAccessor() throws {
        let width = 16, height = 4
        let expected: (Int, Int) -> R12BPacking.Pixel = { x, y in
            R12BPacking.Pixel(r: (x * 211 + y * 37) & 0xFFF,
                              g: (x * 97 + y * 613) & 0xFFF,
                              b: (x * 331 + y * 149) & 0xFFF)
        }
        let frame = try R12BFixtures.makeR12B(width: width, height: height,
                                              code: expected)
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
        let base = try #require(CVPixelBufferGetBaseAddress(frame))
        let rowBytes = CVPixelBufferGetBytesPerRow(frame)
        for y in 0..<height {
            let row = UnsafeRawPointer(base.advanced(by: y * rowBytes))
            for x in 0..<width {
                let got = R12BPacking.pixel(row, x: x)
                let want = expected(x, y)
                #expect(got == want, "pixel (\(x), \(y)): \(got) vs \(want)")
            }
        }
    }

    /// The bulk fixture packer writes the same bytes as the table-based one.
    /// It exists only so a 1080p noise frame is affordable, and this is what
    /// stops it from quietly becoming a second, wrong definition.
    @Test func theTwoPackersAgree() {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> Int {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Int(state & 0xFFF)
        }
        for _ in 0..<200 {
            let components = (0..<R12BPacking.blockComponents).map { _ in next() }
            let fromTable = R12BFixtures.packBlock(components)
            var fromRule = [UInt8](repeating: 0, count: R12BPacking.blockBytes)
            fromRule.withUnsafeMutableBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                R12BFixtures.packBlockFromRule(components, into: base)
            }
            #expect(fromTable == fromRule, "components \(components)")
        }
    }

    /// The stride arithmetic. `packedRowBytes` is the SDK's own formula;
    /// `blockRowBytes` is what a reader touches, and it is the one the
    /// converters guard against — for a width that is not a multiple of eight
    /// they differ, and using the smaller would read past the row.
    @Test func theStrideFormulasSayWhatTheyMean() {
        #expect(R12BPacking.packedRowBytes(width: 1920) == 8640)
        #expect(R12BPacking.packedRowBytes(width: 3840) == 17280)
        #expect(R12BPacking.blockRowBytes(width: 1920) == 8640)
        // a partial trailing block still needs its whole 36 bytes
        #expect(R12BPacking.packedRowBytes(width: 12) == 54)
        #expect(R12BPacking.blockRowBytes(width: 12) == 72)
    }

    /// CoreVideo pads 'R12B' rows out to a 128-pixel boundary, so the stride is
    /// never the SDK formula for a narrow frame — measured, and the reason the
    /// converters take the stride from the buffer instead of computing it.
    @Test func coreVideoPadsNarrowRowsSoTheStrideMustBeRead() throws {
        let frame = try R12BFixtures.makeGrey(width: 16, height: 2) { _, _ in 0 }
        let stride = CVPixelBufferGetBytesPerRow(frame)
        #expect(stride >= R12BPacking.blockRowBytes(width: 16))
        #expect(stride != R12BPacking.packedRowBytes(width: 16),
                "CoreVideo may have stopped padding — stride \(stride)")
    }
}
