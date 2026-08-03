import CoreVideo
import Foundation
import Testing

@testable import CaptureCore

/// Hand-built `'R12B'` frames for the 12-bit tests.
///
/// The packer here is written from Blackmagic's PUBLISHED byte table, field by
/// field, and deliberately shares no code with `R12BPacking` — which derives
/// the same layout from a one-sentence rule about nine big-endian words. That
/// is the whole point: if the rule and the table ever disagree, these tests
/// fail. A fixture that called the production unpacker's inverse would only
/// prove the unpacker is self-consistent.
///
/// No hardware can be involved (there is no board here and the DeckLink runtime
/// may be absent), so the published table is the only authority available — and
/// it is the one the code claims to implement.
enum R12BFixtures {
    /// One field of one byte: which component, and which of its bits.
    struct Field {
        let component: Int // pixel * 3 + channel, channel 0 = R, 1 = G, 2 = B
        let high: Int
        let low: Int

        var width: Int { high - low + 1 }
    }

    private static func f(_ component: Int, _ high: Int, _ low: Int) -> Field {
        Field(component: component, high: high, low: low)
    }

    /// The SDK's table for `bmdFormat12BitRGB`, transcribed as the 36 bytes of
    /// one 8-pixel block in INCREASING address order. Within a byte the fields
    /// are listed most-significant first.
    ///
    /// Component indices: R0 = 0, G0 = 1, B0 = 2, R1 = 3, … B7 = 23.
    ///
    /// Six components straddle a byte pair that is not adjacent — B0 (bytes 0
    /// and 7), B1 (4, 11), G3 (12, 19), G4 (16, 23), R6 (24, 31) and R7 (28,
    /// 35). Those are the awkward ones, and they are why this table is written
    /// out in full instead of being generated.
    static let byteTable: [[Field]] = [
        [f(2, 7, 0)],                    // 0  B0[7:0]
        [f(1, 11, 4)],                   // 1  G0[11:4]
        [f(1, 3, 0), f(0, 11, 8)],       // 2  G0[3:0]  R0[11:8]
        [f(0, 7, 0)],                    // 3  R0[7:0]
        [f(5, 3, 0), f(4, 11, 8)],       // 4  B1[3:0]  G1[11:8]
        [f(4, 7, 0)],                    // 5  G1[7:0]
        [f(3, 11, 4)],                   // 6  R1[11:4]
        [f(3, 3, 0), f(2, 11, 8)],       // 7  R1[3:0]  B0[11:8]
        [f(7, 11, 4)],                   // 8  G2[11:4]
        [f(7, 3, 0), f(6, 11, 8)],       // 9  G2[3:0]  R2[11:8]
        [f(6, 7, 0)],                    // 10 R2[7:0]
        [f(5, 11, 4)],                   // 11 B1[11:4]
        [f(10, 7, 0)],                   // 12 G3[7:0]
        [f(9, 11, 4)],                   // 13 R3[11:4]
        [f(9, 3, 0), f(8, 11, 8)],       // 14 R3[3:0]  B2[11:8]
        [f(8, 7, 0)],                    // 15 B2[7:0]
        [f(13, 3, 0), f(12, 11, 8)],     // 16 G4[3:0]  R4[11:8]
        [f(12, 7, 0)],                   // 17 R4[7:0]
        [f(11, 11, 4)],                  // 18 B3[11:4]
        [f(11, 3, 0), f(10, 11, 8)],     // 19 B3[3:0]  G3[11:8]
        [f(15, 11, 4)],                  // 20 R5[11:4]
        [f(15, 3, 0), f(14, 11, 8)],     // 21 R5[3:0]  B4[11:8]
        [f(14, 7, 0)],                   // 22 B4[7:0]
        [f(13, 11, 4)],                  // 23 G4[11:4]
        [f(18, 7, 0)],                   // 24 R6[7:0]
        [f(17, 11, 4)],                  // 25 B5[11:4]
        [f(17, 3, 0), f(16, 11, 8)],     // 26 B5[3:0]  G5[11:8]
        [f(16, 7, 0)],                   // 27 G5[7:0]
        [f(21, 3, 0), f(20, 11, 8)],     // 28 R7[3:0]  B6[11:8]
        [f(20, 7, 0)],                   // 29 B6[7:0]
        [f(19, 11, 4)],                  // 30 G6[11:4]
        [f(19, 3, 0), f(18, 11, 8)],     // 31 G6[3:0]  R6[11:8]
        [f(23, 11, 4)],                  // 32 B7[11:4]
        [f(23, 3, 0), f(22, 11, 8)],     // 33 B7[3:0]  G7[11:8]
        [f(22, 7, 0)],                   // 34 G7[7:0]
        [f(21, 11, 4)],                  // 35 R7[11:4]
    ]

    /// One 8-pixel block packed from 24 component values, straight off the
    /// table above.
    static func packBlock(_ components: [Int]) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: R12BPacking.blockBytes)
        for (offset, fields) in byteTable.enumerated() {
            var shift = 8
            for field in fields {
                shift -= field.width
                let mask = (1 << field.width) - 1
                let value = (components[field.component] >> field.low) & mask
                bytes[offset] |= UInt8(value << shift)
            }
            // every byte is filled exactly — a table typo shows up here rather
            // than as a mysterious off-by-a-nibble in a picture
            #expect(shift == 0, "byte \(offset) covers \(8 - shift) bits")
        }
        return bytes
    }

    /// The same packing written from the RULE rather than the table, for
    /// fixtures too large to afford the table walk (a 1080p frame is 259 200
    /// blocks). `theTwoPackersAgree` holds it to the table-based one above,
    /// which stays the authority.
    static func packBlockFromRule(_ components: [Int],
                                  into bytes: UnsafeMutablePointer<UInt8>) {
        var words = [UInt32](repeating: 0, count: R12BPacking.blockWords)
        for k in 0..<R12BPacking.blockComponents {
            let bit = k * 12
            let index = bit >> 5
            let shift = bit & 31
            let value = UInt64(components[k] & 0xFFF) << UInt64(shift)
            words[index] |= UInt32(truncatingIfNeeded: value)
            if shift > 20 {
                words[index + 1] |= UInt32(truncatingIfNeeded: value >> 32)
            }
        }
        for (index, word) in words.enumerated() {
            var big = word.bigEndian
            withUnsafeBytes(of: &big) { raw in
                for (offset, byte) in raw.enumerated() {
                    bytes[index * 4 + offset] = byte
                }
            }
        }
    }

    /// A large 'R12B' frame of deterministic pseudo-random 12-bit noise —
    /// the expensive case for the scope accumulator, and what the per-frame
    /// budget has to survive.
    static func makeNoise(width: Int, height: Int,
                          seed: UInt64 = 0x2545_F491_4F6C_DD1D) throws
        -> CVPixelBuffer {
        var out: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            R12BPacking.pixelFormat,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                            &out)
        let buffer = try #require(out)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer))
            .assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let blocks = (width + R12BPacking.blockPixels - 1) / R12BPacking.blockPixels
        var state = seed
        func next() -> Int {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Int(state & 0xFFF)
        }
        var components = [Int](repeating: 0, count: R12BPacking.blockComponents)
        for y in 0..<height {
            for block in 0..<blocks {
                for index in 0..<R12BPacking.blockComponents {
                    components[index] = next()
                }
                packBlockFromRule(
                    components,
                    into: base + y * rowBytes + block * R12BPacking.blockBytes)
            }
        }
        return buffer
    }

    /// An 'R12B' frame whose pixel (x, y) carries `code(x, y)`.
    static func makeR12B(
        width: Int, height: Int,
        code: (_ x: Int, _ y: Int) -> R12BPacking.Pixel
    ) throws -> CVPixelBuffer {
        var out: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            R12BPacking.pixelFormat,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                            &out)
        let buffer = try #require(out, "CoreVideo would not make an 'R12B' buffer")
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer))
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let blocks = (width + R12BPacking.blockPixels - 1) / R12BPacking.blockPixels
        for y in 0..<height {
            let row = base.advanced(by: y * rowBytes)
                .assumingMemoryBound(to: UInt8.self)
            for block in 0..<blocks {
                var components = [Int](repeating: 0, count: R12BPacking.blockComponents)
                for index in 0..<R12BPacking.blockPixels {
                    let x = block * R12BPacking.blockPixels + index
                    guard x < width else { break }
                    let pixel = code(x, y)
                    components[index * 3] = pixel.r
                    components[index * 3 + 1] = pixel.g
                    components[index * 3 + 2] = pixel.b
                }
                let packed = packBlock(components)
                for (offset, byte) in packed.enumerated() {
                    row[block * R12BPacking.blockBytes + offset] = byte
                }
            }
        }
        return buffer
    }

    /// A grey 'R12B' frame — R = G = B, which is what the levels tests want
    /// (nothing in them is measuring chroma).
    static func makeGrey(width: Int, height: Int,
                         code: (_ x: Int, _ y: Int) -> Int) throws -> CVPixelBuffer {
        try makeR12B(width: width, height: height) { x, y in
            let value = code(x, y)
            return R12BPacking.Pixel(r: value, g: value, b: value)
        }
    }

    /// The 12-bit landmarks the levels question is about: the bottom and top of
    /// the legal range, and nominal black and white between them.
    /// Studio swing at 12 bits is 256…3760, with legal excursions 16…4079.
    static let footroom = 16
    static let nominalBlack = 256
    static let midGrey = 2048
    static let nominalWhite = 3760
    static let headroom = 4079
}
