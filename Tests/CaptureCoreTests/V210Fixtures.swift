import CoreVideo
import Foundation
import Testing

@testable import CaptureCore

/// Hand-built `'v210'` frames for the 10-bit YCbCr tests.
///
/// The packer here is written from the format's PUBLISHED layout byte by byte,
/// and deliberately shares no code with `V210Packing` — which derives the same
/// layout from a one-sentence rule about four little-endian words. That is the
/// whole point: if the rule and the byte table ever disagree, these tests fail. A
/// fixture that called the production unpacker's inverse would only prove the
/// unpacker is self-consistent.
///
/// Writing it out per BYTE rather than per word is what makes the table an
/// independent statement at all: "little-endian 32-bit word" is precisely the
/// assumption under test, so the fixture spells out which bits of which
/// component land in which byte and never mentions a word.
///
/// No hardware can be involved (there is no board here and the DeckLink runtime
/// may be absent), so the published layout is the only authority available —
/// plus Apple's own unpacker, which `V210PackingTests` cross-checks against.
enum V210Fixtures {
    /// One field of one byte: which component, and which of its bits.
    /// `component` is nil for the two spare bits at the top of each word.
    struct Field {
        let component: Int?
        let high: Int
        let low: Int

        var width: Int { high - low + 1 }
    }

    private static func f(_ component: Int, _ high: Int, _ low: Int) -> Field {
        Field(component: component, high: high, low: low)
    }

    /// The two bits every fourth byte has left over.
    private static let spare = Field(component: nil, high: 1, low: 0)

    /// The `'v210'` block — six pixels, sixteen bytes — transcribed in
    /// INCREASING address order. Within a byte the fields are listed
    /// most-significant first.
    ///
    /// Component (slot) indices: the twelve slots of a block run
    /// `Cb0 Y0 Cr0 Y1 Cb1 Y2 Cr1 Y3 Cb2 Y4 Cr2 Y5`, where `Cb0`/`Cr0` serve
    /// pixels 0 and 1, `Cb1`/`Cr1` pixels 2 and 3, and `Cb2`/`Cr2` pixels 4
    /// and 5.
    ///
    /// The pattern repeats every four bytes because each group of four holds
    /// three components with two bits spare. Nothing straddles a group, which is
    /// what makes this format kinder than `'R12B'` — but every group DOES split
    /// two of its three components across byte boundaries, and those are the
    /// cases a naive per-byte reader gets wrong.
    static let byteTable: [[Field]] = [
        [f(0, 7, 0)],                 // 0  Cb0[7:0]
        [f(1, 5, 0), f(0, 9, 8)],     // 1  Y0[5:0]   Cb0[9:8]
        [f(2, 3, 0), f(1, 9, 6)],     // 2  Cr0[3:0]  Y0[9:6]
        [spare, f(2, 9, 4)],          // 3  --        Cr0[9:4]
        [f(3, 7, 0)],                 // 4  Y1[7:0]
        [f(4, 5, 0), f(3, 9, 8)],     // 5  Cb1[5:0]  Y1[9:8]
        [f(5, 3, 0), f(4, 9, 6)],     // 6  Y2[3:0]   Cb1[9:6]
        [spare, f(5, 9, 4)],          // 7  --        Y2[9:4]
        [f(6, 7, 0)],                 // 8  Cr1[7:0]
        [f(7, 5, 0), f(6, 9, 8)],     // 9  Y3[5:0]   Cr1[9:8]
        [f(8, 3, 0), f(7, 9, 6)],     // 10 Cb2[3:0]  Y3[9:6]
        [spare, f(8, 9, 4)],          // 11 --        Cb2[9:4]
        [f(9, 7, 0)],                 // 12 Y4[7:0]
        [f(10, 5, 0), f(9, 9, 8)],    // 13 Cr2[5:0]  Y4[9:8]
        [f(11, 3, 0), f(10, 9, 6)],   // 14 Y5[3:0]   Cr2[9:6]
        [spare, f(11, 9, 4)],         // 15 --        Y5[9:4]
    ]

    /// One 6-pixel block packed from 12 component values, straight off the table
    /// above.
    static func packBlock(_ components: [Int]) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: V210Packing.blockBytes)
        for (offset, fields) in byteTable.enumerated() {
            var shift = 8
            for field in fields {
                shift -= field.width
                guard let component = field.component else { continue }
                let mask = (1 << field.width) - 1
                let value = (components[component] >> field.low) & mask
                bytes[offset] |= UInt8(value << shift)
            }
            // every byte is accounted for — a table typo shows up here rather
            // than as a mysterious off-by-two-bits in a picture
            #expect(shift == 0, "byte \(offset) covers \(8 - shift) bits")
        }
        return bytes
    }

    /// The same packing written from the RULE rather than the table, for fixtures
    /// too large to afford the table walk (a 1080p frame is 345 600 blocks).
    /// `theTwoPackersAgree` holds it to the table-based one above, which stays
    /// the authority.
    static func packBlockFromRule(_ components: [Int],
                                  into bytes: UnsafeMutablePointer<UInt8>) {
        for index in 0..<V210Packing.blockWords {
            var word: UInt32 = 0
            for slot in 0..<3 {
                word |= UInt32(components[index * 3 + slot] & 0x3FF)
                    << UInt32(10 * slot)
            }
            var little = word.littleEndian
            withUnsafeBytes(of: &little) { raw in
                for (offset, byte) in raw.enumerated() {
                    bytes[index * 4 + offset] = byte
                }
            }
        }
    }

    /// One pixel of a YCbCr picture, as a fixture describes it. Chroma is stated
    /// per pixel for the caller's convenience and taken from the EVEN pixel of
    /// each pair, because that is where 4:2:2 co-sites it — an odd pixel's
    /// requested chroma is ignored, exactly as the format ignores it.
    struct Sample: Equatable {
        let luma: Int
        let cb: Int
        let cr: Int

        init(luma: Int, cb: Int = V210Fixtures.chromaZero,
             cr: Int = V210Fixtures.chromaZero) {
            self.luma = luma
            self.cb = cb
            self.cr = cr
        }
    }

    /// What goes in the pixels a `'v210'` row has but the picture does not: the
    /// partial trailing block of a width that is not a multiple of six, and the
    /// padding out to the row's 48-pixel boundary.
    ///
    /// Deliberately POISON rather than a copy of the edge pixel. A real board
    /// leaves undefined bytes out there, and a reader that wanders into them
    /// should fail a test loudly rather than come back with something plausible:
    /// black luma with both chroma channels at their opposite extremes is a
    /// violent magenta-green that no expansion can hide.
    static let padding = Sample(luma: 0, cb: 0, cr: V210Packing.maxCode)

    /// A `'v210'` frame whose pixel (x, y) carries `code(x, y)`.
    ///
    /// Every block of the row's real stride is written, the ones past `width`
    /// with `padding` — so a test frame has no accidentally-plausible bytes
    /// anywhere the picture is not.
    static func makeV210(width: Int, height: Int,
                         code: (_ x: Int, _ y: Int) -> Sample) throws
        -> CVPixelBuffer {
        let buffer = try makeBuffer(width: width, height: height)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer))
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let blocks = rowBytes / V210Packing.blockBytes
        for y in 0..<height {
            let row = base.advanced(by: y * rowBytes)
                .assumingMemoryBound(to: UInt8.self)
            for block in 0..<blocks {
                let packed = packBlock(components(block: block, y: y,
                                                 width: width, code: code))
                for (offset, byte) in packed.enumerated() {
                    row[block * V210Packing.blockBytes + offset] = byte
                }
            }
        }
        return buffer
    }

    /// The twelve component values of one block, from the picture where the
    /// block is inside it and from `padding` where it is not.
    private static func components(block: Int, y: Int, width: Int,
                                   code: (_ x: Int, _ y: Int) -> Sample) -> [Int] {
        var out = [Int](repeating: 0, count: V210Packing.blockComponents)
        for p in 0..<V210Packing.blockPixels {
            let x = block * V210Packing.blockPixels + p
            let sample = x < width ? code(x, y) : padding
            out[V210Packing.lumaSlot(p)] = sample.luma
            guard p.isMultiple(of: 2) else { continue }
            out[V210Packing.cbSlot(p / 2)] = sample.cb
            out[V210Packing.crSlot(p / 2)] = sample.cr
        }
        return out
    }

    /// A grey `'v210'` frame — neutral chroma, which is what the levels tests
    /// want (nothing in them is measuring colour) and which is also the case
    /// where the matrix is the identity, so a luma code lands on the display
    /// exactly where an `'r210'` code does.
    static func makeGrey(width: Int, height: Int,
                         luma: (_ x: Int, _ y: Int) -> Int) throws
        -> CVPixelBuffer {
        try makeV210(width: width, height: height) { x, y in
            Sample(luma: luma(x, y))
        }
    }

    /// A large `'v210'` frame of deterministic pseudo-random 10-bit noise — the
    /// expensive case for the scope accumulator and for the converter's chroma
    /// interpolation, and what the per-frame budget has to survive.
    static func makeNoise(width: Int, height: Int,
                          seed: UInt64 = 0x2545_F491_4F6C_DD1D) throws
        -> CVPixelBuffer {
        let buffer = try makeBuffer(width: width, height: height)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer))
            .assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let blocks = rowBytes / V210Packing.blockBytes
        var state = seed
        func next() -> Int {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Int(state & 0x3FF)
        }
        var components = [Int](repeating: 0, count: V210Packing.blockComponents)
        for y in 0..<height {
            for block in 0..<blocks {
                for index in 0..<V210Packing.blockComponents {
                    components[index] = next()
                }
                packBlockFromRule(
                    components,
                    into: base + y * rowBytes + block * V210Packing.blockBytes)
            }
        }
        return buffer
    }

    private static func makeBuffer(width: Int, height: Int) throws
        -> CVPixelBuffer {
        var out: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            V210Packing.pixelFormat,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                            &out)
        return try #require(out, "CoreVideo would not make a 'v210' buffer")
    }

    /// The 10-bit landmarks the levels question is about: the ends of what a
    /// camera legally rides to, and nominal black and white between them.
    /// Studio swing is 64…940, with legal excursions 4…1019 — and 0…3 and
    /// 1020…1023 are reserved for SDI's sync words, so they cannot appear in a
    /// picture at all.
    static let footroom = 4
    static let nominalBlack = 64
    static let midGrey = 500
    static let nominalWhite = 940
    static let headroom = 1019
    /// The code both chroma channels sit on when there is no colour.
    static let chromaZero = 512
}
