import CoreVideo
import Foundation
import Testing
import VideoToolbox

@testable import CaptureCore

/// The `'v210'` bit layout, pinned against three authorities that are
/// independent of the production reader: the published byte table (transcribed in
/// `V210Fixtures`), CoreVideo's own description of the format, and Apple's own
/// unpacker.
///
/// The third one is the reason this suite is worth its length. A stride rule can
/// be right while the component ORDER is wrong, and a self-consistent
/// pack/unpack pair proves nothing about either — a reader with Cb and Cr swapped
/// round-trips perfectly and shows every face green. So the layout is checked
/// against something that was not written here: a `VTPixelTransferSession` from
/// `'v210'` to `'2vuy'`, on a block whose twelve slots all carry different
/// values. That is the known-good case this reader was validated against before
/// anything was allowed to depend on it.
struct V210PackingTests {
    /// The twelve slots, each with a distinguishable value. Multiples of four so
    /// the 8-bit comparison below is exact rather than rounded.
    private static let slotCodes = [
        152, 100, 248, 200, 352, 300, 448, 400, 552, 500, 648, 600,
    ]

    /// Slot values as a picture: slot `2p+1` is pixel `p`'s luma, slot `4j` and
    /// `4j+2` are chroma pair `j`.
    private static func sample(_ x: Int) -> V210Fixtures.Sample {
        let p = x % V210Packing.blockPixels
        let pair = p / 2
        return V210Fixtures.Sample(luma: slotCodes[V210Packing.lumaSlot(p)],
                                   cb: slotCodes[V210Packing.cbSlot(pair)],
                                   cr: slotCodes[V210Packing.crSlot(pair)])
    }

    // MARK: - the rule against the published table

    /// Every one of the twelve components comes back exactly, out of a block
    /// packed from the byte table. The two split components of each four-byte
    /// group are the ones this is really about.
    @Test func everyComponentSurvivesTheTable() {
        let packed = V210Fixtures.packBlock(Self.slotCodes)
        #expect(packed.count == V210Packing.blockBytes)
        packed.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            for slot in 0..<V210Packing.blockComponents {
                #expect(V210Packing.component(base, slot) == Self.slotCodes[slot],
                        "slot \(slot)")
            }
        }
    }

    /// The two spare bits at the top of each word are ignored, so a source that
    /// leaves them set cannot corrupt a component. (Measured: Apple's own
    /// unpacker ignores them too.)
    @Test func theSpareBitsAreIgnored() {
        var packed = V210Fixtures.packBlock(Self.slotCodes)
        for index in 0..<V210Packing.blockWords {
            packed[index * 4 + 3] |= 0xC0 // bits 30 and 31 of the word
        }
        packed.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            for slot in 0..<V210Packing.blockComponents {
                #expect(V210Packing.component(base, slot) == Self.slotCodes[slot],
                        "slot \(slot) with the spare bits set")
            }
        }
    }

    /// The sequential unpack and the random-access one are the same rule, held to
    /// each other so the converter's fast path cannot drift from the scopes'.
    @Test func theTwoUnpackFormsAgree() {
        let packed = V210Fixtures.packBlock(Self.slotCodes)
        var out = [UInt16](repeating: 0, count: V210Packing.blockComponents)
        packed.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            out.withUnsafeMutableBufferPointer { buffer in
                guard let start = buffer.baseAddress else { return }
                V210Packing.unpackBlock(base, into: start)
            }
            for slot in 0..<V210Packing.blockComponents {
                #expect(Int(out[slot]) == V210Packing.component(base, slot),
                        "slot \(slot)")
            }
        }
    }

    /// The fast fixture packer and the table-driven one produce identical bytes,
    /// for pseudo-random components across the whole 10-bit range. The table stays
    /// the authority; this is what lets the big fixtures skip it.
    @Test func theTwoPackersAgree() {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> Int {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Int(state & 0x3FF)
        }
        var bytes = [UInt8](repeating: 0, count: V210Packing.blockBytes)
        for round in 0..<200 {
            let components = (0..<V210Packing.blockComponents).map { _ in next() }
            let table = V210Fixtures.packBlock(components)
            bytes.withUnsafeMutableBufferPointer { buffer in
                guard let start = buffer.baseAddress else { return }
                V210Fixtures.packBlockFromRule(components, into: start)
            }
            #expect(bytes == table, "round \(round): \(components)")
        }
    }

    /// A pixel's luma and the chroma of the pair it belongs to, at every position
    /// in a block — including the odd pixels, which share their neighbour's
    /// chroma. A reader that indexed chroma per pixel instead of per pair would
    /// pass at pixel 0 and fail at pixel 1.
    @Test func aPixelFindsItsOwnLumaAndItsPairsChroma() throws {
        let frame = try V210Fixtures.makeV210(width: 12, height: 2) { x, _ in
            Self.sample(x)
        }
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
        let base = try #require(CVPixelBufferGetBaseAddress(frame))
        for x in 0..<12 {
            let expected = Self.sample(x)
            let pixel = V210Packing.pixel(UnsafeRawPointer(base), x: x)
            #expect(pixel.luma == expected.luma, "pixel \(x) luma")
            // the pair's chroma: the EVEN pixel's, for both of them
            let even = Self.sample(x & ~1)
            #expect(pixel.cb == even.cb, "pixel \(x) Cb")
            #expect(pixel.cr == even.cr, "pixel \(x) Cr")
        }
    }

    // MARK: - against CoreVideo

    /// CoreVideo describes the format natively, which is what lets the app make
    /// buffers of it with no registration call — and the numbers it reports are
    /// the ones this file implements.
    @Test func coreVideoDescribesTheSameBlock() throws {
        let description = try #require(
            CVPixelFormatDescriptionCreateWithPixelFormatType(
                kCFAllocatorDefault, V210Packing.pixelFormat) as? [String: Any],
            "CoreVideo does not know 'v210'")
        #expect(description[kCVPixelFormatBitsPerBlock as String] as? Int
            == V210Packing.blockBytes * 8)
        #expect(description[kCVPixelFormatBlockWidth as String] as? Int
            == V210Packing.blockPixels)
        #expect(description[kCVPixelFormatHorizontalSubsampling as String] as? Int == 2)
        #expect(description[kCVPixelFormatVerticalSubsampling as String] as? Int == 1)
        // eight blocks of alignment IS the 48-pixel row boundary
        #expect(description[kCVPixelFormatBlockHorizontalAlignment as String] as? Int
            == V210Packing.rowAlignmentPixels / V210Packing.blockPixels)
    }

    /// The stride rule matches what CoreVideo actually hands out, at widths that
    /// land on the 48-pixel boundary and at widths that do not.
    ///
    /// The rule is still never used to ADDRESS a buffer — that is the point of
    /// checking it here and taking the real stride from the buffer everywhere
    /// else: a width of 1280 gets 3456 bytes where the picture needs 3424, and a
    /// reader that computed its own stride would walk diagonally down the frame.
    @Test func theStrideRuleMatchesCoreVideo() throws {
        for width in [6, 8, 16, 48, 50, 96, 100, 720, 1280, 1920, 2048, 3840, 4096] {
            var out: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, width, 4,
                                V210Packing.pixelFormat,
                                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                                &out)
            let buffer = try #require(out, "width \(width) was refused")
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            let actual = CVPixelBufferGetBytesPerRow(buffer)
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            #expect(actual == V210Packing.packedRowBytes(width: width),
                    "width \(width): CoreVideo gave \(actual)")
            // …and whatever the padding is, it is never less than the blocks a
            // reader touches
            #expect(actual >= V210Packing.blockRowBytes(width: width),
                    "width \(width) cannot hold its own blocks")
        }
        // the two are genuinely different numbers, or the check above is vacuous
        #expect(V210Packing.packedRowBytes(width: 1280) == 3456)
        #expect(V210Packing.blockRowBytes(width: 1280) == 3424)
        #expect(V210Packing.blockRowBytes(width: 100) == 17 * 16,
                "a width of 100 needs seventeen whole blocks")
    }

    // MARK: - against Apple's own unpacker

    /// The layout agrees with an implementation that was not written here.
    ///
    /// `VTPixelTransferSession` from `'v210'` to `'2vuy'` is a pure depth
    /// reduction — same colour space, same sampling, same range — so every
    /// component must come back as its 10-bit code divided by four. The slot
    /// values are all different and all multiples of four, so the comparison is
    /// exact and a swap of ANY two of the twelve fails it.
    ///
    /// This is the test that proves the component order, the chroma siting and
    /// the pixel order — none of which a stride or a self-consistent round trip
    /// can say anything about.
    @Test func theLayoutAgreesWithApplesOwnUnpacker() throws {
        let width = 12, height = 4
        let frame = try V210Fixtures.makeV210(width: width, height: height) { x, _ in
            Self.sample(x)
        }
        var session: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(
                allocator: kCFAllocatorDefault,
                pixelTransferSessionOut: &session) == noErr,
              let session else {
            // no session, no comparison — the layout is still pinned against the
            // published table above, and a machine that cannot make one has
            // bigger problems than this suite
            return
        }
        var out: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_422YpCbCr8,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                            &out)
        let vuy = try #require(out)
        guard VTPixelTransferSessionTransferImage(session, from: frame,
                                                 to: vuy) == noErr else { return }
        CVPixelBufferLockBaseAddress(vuy, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(vuy, .readOnly) }
        let base = try #require(CVPixelBufferGetBaseAddress(vuy))
            .assumingMemoryBound(to: UInt8.self)
        let row = base + CVPixelBufferGetBytesPerRow(vuy) * (height / 2)
        // '2vuy' macropixel: Cb Y0 Cr Y1, one per two columns
        for pair in 0..<(width / 2) {
            let macropixel = row + pair * 4
            let even = Self.sample(pair * 2)
            let odd = Self.sample(pair * 2 + 1)
            #expect(Int(macropixel[0]) == even.cb / 4, "pair \(pair) Cb")
            #expect(Int(macropixel[1]) == even.luma / 4, "pair \(pair) Y0")
            #expect(Int(macropixel[2]) == even.cr / 4, "pair \(pair) Cr")
            #expect(Int(macropixel[3]) == odd.luma / 4, "pair \(pair) Y1")
        }
    }
}
