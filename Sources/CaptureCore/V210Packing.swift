@preconcurrency import CoreVideo
import Foundation

/// The packing of 10-bit YCbCr 4:2:2 — `'v210'` (`bmdFormat10BitYUV`,
/// `kCVPixelFormatType_422YpCbCr10`) — the ONE place in the project that knows
/// how those bits are arranged.
///
/// Two readers go through it and neither owns a second copy: the capture split
/// (`TenBitYUVConverter`) walks whole blocks sequentially, and the scopes
/// (`ScopeAnalyzer.V210Reader`) sample a sparse grid at random. This is the same
/// arrangement `R12BPacking` has for the 12-bit RGB format, and for the same
/// reason: a duplicated bit table drifts, and a drift here is a torn or
/// false-coloured picture rather than a compile error.
///
/// ## Source
///
/// The layout is Apple's published `'v210'` definition (the ICT note
/// "Uncompressed Y'CbCr Video in QuickTime Files"), which is also what
/// Blackmagic's `bmdFormat10BitYUV` is — the SDK documents the stride as
/// `((width + 47) / 48) * 128` and calls the format v210. It is corroborated
/// three ways, and the third is a measurement rather than a document:
///
/// - CoreVideo describes the format natively — measured with
///   `CVPixelFormatDescriptionCreateWithPixelFormatType`: BitsPerBlock 128,
///   BlockWidth 6, HorizontalSubsampling 2, VerticalSubsampling 1,
///   BlockHorizontalAlignment 8. So no format registration is needed to make
///   buffers of it, and eight blocks of alignment IS the 48-pixel row boundary;
/// - the stride rule above matches what CoreVideo actually hands out, checked at
///   thirteen widths from 6 to 4096 (`V210PackingTests`);
/// - Apple's own unpacker agrees with the rule below, component for component:
///   a `VTPixelTransferSession` from `'v210'` to `'2vuy'` returns
///   `round(code / 4)` for every one of the twelve slots of a block loaded with
///   twelve different values. That is the known-good case this reader was
///   validated against before it was trusted, and it is what proves the
///   component ORDER and the chroma siting, which no stride can.
///
/// ## The rule
///
/// > Six pixels live in sixteen bytes, read as four LITTLE-endian `UInt32`s.
/// > Each word carries three 10-bit components, at bits 0…9, 10…19 and 20…29;
/// > the top two bits of every word are unused. The twelve components of the
/// > six pixels then lie in slot order
/// > `Cb Y0 Cr Y1  Cb Y2 Cr Y3  Cb Y4 Cr Y5` — the same Cb Y Cr Y order
/// > `'2vuy'` uses, one depth up, with each chroma pair co-sited with the EVEN
/// > luma of the two pixels it serves.
///
/// Nothing straddles a word boundary here, which is the one way this format is
/// kinder than `'R12B'`: three 10-bit components fit a 32-bit word with two bits
/// to spare. The awkward cases are elsewhere — a width that is not a multiple of
/// six leaves a partial 16-byte block, and CoreVideo pads every row out to 48
/// pixels, so the stride ALWAYS comes from `CVPixelBufferGetBytesPerRow` and is
/// never computed. `packedRowBytes` exists to describe the format, not to
/// address a buffer.
///
/// The two spare bits at the top of each word are ignored by Apple's unpacker
/// (measured: setting them changed nothing in the transfer above), and this
/// reader masks them off for the same reason. A writer leaves them zero.
///
/// ## Range
///
/// `'v210'` is video-range YCbCr by definition: nominal black 64, nominal white
/// 940, chroma zero 512 over 64…960, with legal excursions on both sides and
/// codes 0…3 and 1020…1023 reserved (they carry SDI's sync words and cannot
/// appear in picture). Unlike `'R12B'`, whose container CLAIMS full range, there
/// is no ambiguity to resolve here — but levels stay the operator's setting all
/// the same, because a playout device set to Full is a thing that exists. See
/// `InputLevels`.
enum V210Packing {
    /// `'v210'`, the FourCC the board labels the frame with and the one
    /// CoreVideo already knows.
    static let pixelFormat = kCVPixelFormatType_422YpCbCr10
    /// Six pixels per block…
    static let blockPixels = 6
    /// …and sixteen bytes to hold them (128 bits = 12 components x 10 bits,
    /// plus two spare bits in each of the four words).
    static let blockBytes = 16
    /// Words per block, as the rule above reads them.
    static let blockWords = 4
    /// Components per block: six luma and three chroma pairs.
    static let blockComponents = 12
    /// The top code of a 10-bit component.
    static let maxCode = 1023
    /// Rows are padded out to this many pixels — eight blocks, which is the
    /// BlockHorizontalAlignment CoreVideo reports. Stated so `packedRowBytes`
    /// can describe the format; the stride in use always comes from the buffer.
    static let rowAlignmentPixels = 48
    /// The chroma pairs in a block: one per two pixels.
    static let blockChromaPairs = blockPixels / 2

    /// Component `k` (0…11) of the block at `base` — the random-access form, for
    /// the scopes' sparse sampling grid.
    ///
    /// `loadUnaligned` because a row stride the board or CoreVideo chose is not
    /// required to keep 16-byte blocks 4-byte aligned — and it cannot trap,
    /// where a bound load could.
    @inline(__always)
    static func component(_ base: UnsafeRawPointer, _ k: Int) -> Int {
        let word = UInt32(littleEndian: base.loadUnaligned(
            fromByteOffset: (k / 3) * 4, as: UInt32.self))
        return Int((word >> UInt32(10 * (k % 3))) & 0x3FF)
    }

    /// Which slot pixel `p` of a block keeps its luma in. The twelve slots run
    /// Cb Y Cr Y …, so every odd slot is a luma.
    @inline(__always)
    static func lumaSlot(_ p: Int) -> Int { 2 * p + 1 }

    /// The Cb slot of chroma pair `pair` (0…2), which serves pixels 2·pair and
    /// 2·pair + 1.
    @inline(__always)
    static func cbSlot(_ pair: Int) -> Int { 4 * pair }

    /// …and its Cr slot.
    @inline(__always)
    static func crSlot(_ pair: Int) -> Int { 4 * pair + 2 }

    /// One pixel's luma and the chroma pair it shares with its neighbour. A
    /// named type rather than a tuple — the project caps tuples at two members,
    /// and `.cb`/`.cr` at the call sites is what catches a channel swap.
    struct Pixel: Equatable {
        let luma: Int
        let cb: Int
        let cr: Int
    }

    /// Pixel `x` of a row, carrying the chroma of the PAIR it belongs to —
    /// nearest, not interpolated. For a measurement that is the honest reading:
    /// it is the sample the source actually coded, and a vectorscope must plot
    /// what arrived rather than what an upsampler would have invented. The
    /// picture path interpolates instead, and says why — see
    /// `TenBitYUVConverter`.
    @inline(__always)
    static func pixel(_ row: UnsafeRawPointer, x: Int) -> Pixel {
        let base = row + (x / blockPixels) * blockBytes
        let p = x % blockPixels
        let pair = p / 2
        return Pixel(luma: component(base, lumaSlot(p)),
                     cb: component(base, cbSlot(pair)),
                     cr: component(base, crSlot(pair)))
    }

    /// Every component of one block, in slot order — the sequential form, for
    /// the converter's row walk.
    ///
    /// Same rule as `component(_:_:)` and the tests hold the two to each other,
    /// but this makes FOUR loads instead of up to twelve for the same values,
    /// which is what the per-frame budget notices at UHD.
    ///
    /// `out` must have room for `blockComponents`.
    @inline(__always)
    static func unpackBlock(_ base: UnsafeRawPointer,
                            into out: UnsafeMutablePointer<UInt16>) {
        for index in 0..<blockWords {
            let word = UInt32(littleEndian: base.loadUnaligned(
                fromByteOffset: index * 4, as: UInt32.self))
            out[index * 3] = UInt16(word & 0x3FF)
            out[index * 3 + 1] = UInt16((word >> 10) & 0x3FF)
            out[index * 3 + 2] = UInt16((word >> 20) & 0x3FF)
        }
    }

    /// Bytes one row of `width` pixels occupies in the format's own stride —
    /// `((width + 47) / 48) * 128`. Used only to DESCRIBE the format, never to
    /// address a buffer: the row of a `CVPixelBuffer` is padded out to 48 pixels
    /// (measured: width 1280 gets 3456 bytes, not 3424), so the stride always
    /// comes from `CVPixelBufferGetBytesPerRow`.
    static func packedRowBytes(width: Int) -> Int {
        ((width + rowAlignmentPixels - 1) / rowAlignmentPixels)
            * (rowAlignmentPixels / blockPixels) * blockBytes
    }

    /// Bytes a reader actually TOUCHES for a row of `width` pixels — whole
    /// blocks, rounded up. A width that is not a multiple of six makes this
    /// larger than the picture, and a row stride below it cannot be unpacked
    /// without reading past the row.
    static func blockRowBytes(width: Int) -> Int {
        ((width + blockPixels - 1) / blockPixels) * blockBytes
    }
}
