@preconcurrency import CoreVideo
import Foundation

/// The packing of Blackmagic's 12-bit RGB wire format, `'R12B'`
/// (`bmdFormat12BitRGB`) — the ONE place in the project that knows how those
/// bits are arranged.
///
/// Two readers go through it and neither owns a second copy: the capture split
/// (`TwelveBitConverter`) walks whole blocks sequentially, and the scopes
/// (`ScopeAnalyzer.R12BReader`) sample a sparse grid at random. A duplicated
/// bit table is exactly the kind of thing that drifts, and a drift here is a
/// torn or false-coloured picture rather than a compile error.
///
/// ## Source
///
/// The layout is Blackmagic's published pixel-format table for
/// `bmdFormat12BitRGB` (DeckLink SDK documentation, "Pixel Formats"). It is
/// corroborated three ways:
///
/// - the SDK header's own description — `bmdFormat12BitRGB = 'R12B'`,
///   "Big-endian RGB 12-bit per component with full range (0-4095). Packed as
///   12-bit per component";
/// - the documented stride `rowBytes = (width * 36) / 8`, i.e. 8 pixels in
///   36 bytes, which is what the rule below produces;
/// - CoreVideo, which already describes `'R12B'` natively as BitsPerBlock 288,
///   BlockWidth 8, BitsPerComponent 12, ComponentRange FullRange — so no
///   `CVPixelFormatDescriptionRegisterDescriptionWithPixelFormatType` call is
///   needed to make buffers of this format.
///
/// The same parse applied to the SDK's `'r210'` table reproduces the shipped
/// `TenBitConverter` unpack exactly, which is what gives confidence that the
/// table's "decreasing address order" columns have been read the right way
/// round.
///
/// ## The rule
///
/// The SDK states the format as nine 32-bit words with their bytes listed in
/// DECREASING address order. Read in increasing address order it collapses to
/// one sentence, which is what this file implements:
///
/// > Load the 36 bytes as nine BIG-ENDIAN `UInt32`s w0…w8 and concatenate them
/// > LITTLE-end first — w0 is bits 0…31 of a 288-bit value, w1 is bits 32…63,
/// > and so on. The 24 components of the eight pixels then lie in that value in
/// > plain order R0, G0, B0, R1, G1, B1, …, R7, G7, B7, with component `k`
/// > occupying bits `12k … 12k+11`.
///
/// Six of the 24 components straddle a word boundary under that rule — B0, B1,
/// G3, G4, R6 and R7 — and those are the awkward pixels a naive per-word
/// unpack gets wrong. `R12BPackingTests` pins every one of the 24 components
/// against the published byte table.
///
/// ## Range
///
/// Both the SDK and CoreVideo call this format full-range 0…4095. That is a
/// statement about the CONTAINER, not about what a camera puts in it: an HDMI
/// RGB 4:4:4 source is studio swing by CTA-861 default, which at 12 bits is
/// nominal black 256 and nominal white 3760. Levels stay the operator's
/// setting, exactly as they are for `'r210'` — see `InputLevels`.
enum R12BPacking {
    /// `'R12B'`, the FourCC the board labels the frame with and the one
    /// CoreVideo already knows.
    static let pixelFormat = OSType(0x5231_3242)
    /// Eight pixels per block…
    static let blockPixels = 8
    /// …and 36 bytes to hold them (288 bits = 24 components x 12 bits).
    static let blockBytes = 36
    /// Words per block, as the rule above reads them.
    static let blockWords = 9
    /// Components per block: three per pixel, no alpha.
    static let blockComponents = 24
    /// The top code of a 12-bit component.
    static let maxCode = 4095

    /// Big-endian word `index` of the block at `base`, widened for the shifts
    /// below. `loadUnaligned` because a row stride the board or CoreVideo chose
    /// is not required to keep 36-byte blocks 4-byte aligned — and it cannot
    /// trap, where a bound load could.
    @inline(__always)
    static func word(_ base: UnsafeRawPointer, _ index: Int) -> UInt64 {
        UInt64(UInt32(bigEndian: base.loadUnaligned(fromByteOffset: index * 4,
                                                    as: UInt32.self)))
    }

    /// Component `k` (0…23) of the block at `base` — the random-access form,
    /// for the scopes' sparse sampling grid.
    ///
    /// A component starts at bit `12k` and is 11 bits wide, so it stays inside
    /// its own word only while `shift <= 20`; past that it borrows from the
    /// next one. The last component (k = 23) starts at bit 276, which is
    /// shift 20 of word 8 — exactly on the limit — so the second load is never
    /// asked for a tenth word.
    @inline(__always)
    static func component(_ base: UnsafeRawPointer, _ k: Int) -> Int {
        let bit = k * 12
        let index = bit >> 5
        let shift = bit & 31
        var value = word(base, index) >> UInt64(shift)
        if shift > 20 {
            value |= word(base, index + 1) << UInt64(32 - shift)
        }
        return Int(value & 0xFFF)
    }

    /// One pixel's three 12-bit components. A named type rather than a tuple —
    /// the project caps tuples at two members, and `.r`/`.g`/`.b` at the call
    /// sites is what catches a channel swap.
    struct Pixel: Equatable {
        let r: Int
        let g: Int
        let b: Int
    }

    /// The three components of pixel `x` of a row.
    @inline(__always)
    static func pixel(_ row: UnsafeRawPointer, x: Int) -> Pixel {
        let base = row + (x / blockPixels) * blockBytes
        let k = (x % blockPixels) * 3
        return Pixel(r: component(base, k), g: component(base, k + 1),
                     b: component(base, k + 2))
    }

    /// Every component of one block, in order — the sequential form, for the
    /// converter's row walk.
    ///
    /// Same rule as `component(_:_:)` and the tests hold the two to each other,
    /// but this makes NINE loads instead of up to thirty for the same 24
    /// values, which is what the per-frame budget notices at UHD.
    ///
    /// `out` must have room for `blockComponents`.
    @inline(__always)
    static func unpackBlock(_ base: UnsafeRawPointer,
                            into out: UnsafeMutablePointer<UInt16>) {
        var accumulator: UInt64 = 0
        var have = 0 // bits currently held, always 0, 4 or 8 on entry
        var written = 0
        for index in 0..<blockWords {
            // `have` is at most 8 here, so a 32-bit word shifted up by it
            // reaches bit 39 and nothing is ever shifted out of the top
            accumulator |= word(base, index) << UInt64(have)
            have += 32
            while have >= 12 {
                out[written] = UInt16(accumulator & 0xFFF)
                written += 1
                accumulator >>= 12
                have -= 12
            }
        }
    }

    /// Bytes one row of `width` pixels occupies in the SDK's own stride —
    /// `(width * 36) / 8`. Used only to describe the format, never to address a
    /// buffer: a `CVPixelBuffer` of 'R12B' pads its rows out to a 128-pixel
    /// boundary (measured: width 720 gets 3456 bytes, not 3240), so the stride
    /// always comes from `CVPixelBufferGetBytesPerRow`.
    static func packedRowBytes(width: Int) -> Int {
        (width * blockBytes) / blockPixels
    }

    /// Bytes a reader actually TOUCHES for a row of `width` pixels — whole
    /// blocks, rounded up. A width that is not a multiple of eight makes this
    /// larger than `packedRowBytes`, and a row stride below it cannot be
    /// unpacked without reading past the row.
    static func blockRowBytes(width: Int) -> Int {
        ((width + blockPixels - 1) / blockPixels) * blockBytes
    }
}
