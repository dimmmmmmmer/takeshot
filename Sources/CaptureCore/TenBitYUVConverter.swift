@preconcurrency import CoreVideo
import Foundation

/// Converter for 10-bit YCbCr 4:2:2 capture (`'v210'`, `bmdFormat10BitYUV` — six
/// pixels packed into sixteen bytes; see `V210Packing`). The standard
/// professional SDI signal, and the format an 8-bit YUV capture was throwing two
/// bits away to avoid.
///
/// The third member of the wire-converter family, and it answers to the same
/// rule as `TenBitConverter` (`'r210'`) and `TwelveBitConverter` (`'R12B'`): one
/// pass over the wire frame produces exactly two products, because the picture
/// and the deliverable want different things from the same codes. What is
/// different here is which of the two turns out to be the easy one.
///
/// - the **display** product is the one that costs something. A YCbCr frame is
///   not R'G'B', and it is not 4:4:4 — so it goes through the matrix
///   (`WireYCbCr`, which changes colour space and deliberately not swing) and a
///   chroma upsample, and only then through `WireDisplayTable`, the same levels
///   table the two RGB converters use. A 10-bit YCbCr source and a 10-bit RGB
///   source therefore reach the monitor through one table and cannot drift.
/// - the **record** product is the wire frame ITSELF, returned unchanged and
///   uncopied. Not a conversion, not a copy: `'v210'` is already exactly what
///   the encoder wants. This is the only path in the app where that is true, and
///   it is worth stating why in full, because it is the answer to two separate
///   questions at once.
///
/// ## Why the record product is the wire frame
///
/// Measured through a real ProRes encode and decode (`TenBitYUVRecordTests`):
/// VideoToolbox takes a `'v210'` buffer into the 4:2:2 ProRes family and hands
/// the codes straight back. Luma bands 4, 64, 500, 940 and 1019 come back as 4,
/// 64, 500, 940 and 1019; chroma 64, 512 and 960 come back as 64, 512 and 960.
/// No video-range window, no expansion inside the codec, no precompensation
/// needed — so the file is wire-EXACT, and it is the first path in this app that
/// is wire-exact AND needs no conversion to get there.
///
/// Where `TenBitConverter` has to precompensate (VT reads `'r210'` as
/// video-range 64–960 and expands it inside the codec, so a 10-bit RGB file is
/// wire-referred), and `TwelveBitConverter` gets wire-exactness only by moving
/// to a 16-bit container, this one gets it by doing nothing at all. The measured
/// limit is not a window but SMPTE's reserved codes: 0 and 1023 come back as 4
/// and 1019, because 0…3 and 1020…1023 carry SDI's sync words and cannot appear
/// in a picture. A real signal cannot reach them.
///
/// ## Why the take carries no levels key
///
/// A `'v210'` take is a video-range YCbCr ProRes file with Rec.709 tags — which
/// is precisely what every tool downstream, including AVFoundation, already
/// knows how to read. Measured: decoding the file to BGRA returns 0 for wire 64
/// and 255 for wire 940, with the excursions clipped, which is the same picture
/// the live display buffer shows. So `recordNeedsPlaybackExpansion` is false and
/// the take is written WITHOUT `com.takeshot.levels = "wire"` — the RGB paths
/// need that key because there is no standard way for an RGB coded picture to
/// say "these are studio-swing codes", and a YCbCr one says it by construction.
/// Tagging a v210 take as wire would expand it a second time and crush its
/// shadows, which is the exact failure the key exists to prevent.
///
/// This is also what today's 8-bit `'2vuy'` takes already do — they are written
/// untagged and they play back correctly. The 10-bit path is the same file, one
/// depth up.
public final class TenBitYUVConverter: WireConverter {
    /// `'v210'`.
    public static let v210 = V210Packing.pixelFormat

    public var wireFormat: OSType { Self.v210 }
    /// The record product IS the wire frame, so the record format is the wire
    /// format — see the note above.
    public var recordPixelFormat: OSType { Self.v210 }
    /// `'v210'` is 128 bits per six pixels, i.e. 2⅔ bytes a pixel. Rounded UP,
    /// because the pre-roll ring divides a byte budget by this: rounding down
    /// would let the ring hold more frames than the budget allows.
    public var recordBytesPerPixel: Int { 3 }
    /// No. A video-range YCbCr file states its own range through the standard
    /// tags and the decoder acts on it, so expanding it again on the way out
    /// would crush the shadows. Measured — see the note above.
    public var recordNeedsPlaybackExpansion: Bool { false }

    /// wire code (0…1023) → the value that appears on the DISPLAY. The same
    /// shared table the RGB converters use, at the same depth as `'r210'`.
    private var expand = WireDisplayTable.expand(levels: .limited, bits: 10)
    /// YCbCr → R'G'B' on the wire's own swing. Rebuilt with the levels mode
    /// because the luma and chroma scales differ under studio swing and not
    /// under full — see `WireYCbCr`.
    ///
    /// `InputLevels` is named in full because `WireYCbCr` takes either levels
    /// enum and both of them have a `.limited`, so a bare leading dot is
    /// genuinely ambiguous here.
    private var matrix = WireYCbCr(levels: InputLevels.limited)
    private var levels = InputLevels.limited

    private let displayPool = PixelBufferPool()

    public init() {}

    /// The resolved input-levels mode for the current source.
    ///
    /// `limited` is what auto resolves to for a signal that is not RGB 4:4:4,
    /// and for YCbCr that is not a guess: SDI is studio swing by SMPTE and HDMI
    /// YCbCr is studio swing by CTA-861. `full` exists for the playout device
    /// that has been set to Full output.
    ///
    /// Only the DISPLAY products have a mode to rebuild for; the record product
    /// is the wire frame, which is the strongest possible form of "levels never
    /// reach the file".
    public func setLevels(_ newLevels: InputLevels) {
        guard newLevels != levels else { return }
        levels = newLevels
        expand = WireDisplayTable.expand(levels: newLevels, bits: 10)
        matrix = WireYCbCr(levels: newLevels)
    }

    /// Split a `'v210'` wire frame into (display BGRA8, record `'v210'`), where
    /// the record half is the frame that came in. Runs on the pipeline queue,
    /// banded across cores like the two RGB paths.
    public func convert(_ source: CVPixelBuffer)
        -> (display: CVPixelBuffer, record: CVPixelBuffer)? {
        guard CVPixelBufferGetPixelFormatType(source) == Self.v210
        else { return nil }
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        guard let display = displayPool.buffer(width: width, height: height)
        else { return nil }
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(display, [])
        defer {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
            CVPixelBufferUnlockBaseAddress(display, [])
        }
        guard let sourceBase = CVPixelBufferGetBaseAddress(source),
              let displayBase = CVPixelBufferGetBaseAddress(display)
        else { return nil }
        let sbpr = CVPixelBufferGetBytesPerRow(source)
        // A short row would make the last block read past its end. Refusing the
        // frame drops it visibly (the pipeline counts it) instead of unpacking
        // whatever follows the row into the picture.
        guard sbpr >= V210Packing.blockRowBytes(width: width) else { return nil }
        convertBands(
            source: Plane(base: sourceBase, rowBytes: sbpr),
            display: Plane(base: displayBase,
                           rowBytes: CVPixelBufferGetBytesPerRow(display)),
            width: width, height: height)
        // the record product is the frame that came in — see the type's note
        return (display, source)
    }

    /// The banded pass, split out so `convert` stays a statement of the two
    /// products and their guards.
    private func convertBands(source: Plane, display: Plane,
                              width: Int, height: Int) {
        // nonisolated(unsafe): the bands below run concurrently over these
        // pointers, and that is safe by construction — each band owns a disjoint
        // range of rows and the table is read-only for the whole pass.
        nonisolated(unsafe) let src = source
        nonisolated(unsafe) let dst = display
        let bands = min(8, max(1, height / 270))
        let matrix = self.matrix
        expand.withUnsafeBufferPointer { expandTable in
            // read-only for the whole pass — see the note above
            nonisolated(unsafe) let exp = expandTable
            // the type is named in full: `Self` inside a closure reads as a
            // capture of the instance, and nothing here may retain it
            DispatchQueue.concurrentPerform(iterations: bands) { band in
                TenBitYUVConverter.convertRows(
                    (band * height / bands)..<((band + 1) * height / bands),
                    Pass(source: src, display: dst,
                         width: width, expand: exp, matrix: matrix))
            }
        }
    }

    /// One locked buffer as the row loop sees it. The two planes have different
    /// element widths — 16 bytes per 6 source pixels, 4 bytes per display
    /// pixel — so the row accessor is offered raw and typed.
    private struct Plane {
        let base: UnsafeMutableRawPointer
        let rowBytes: Int

        @inline(__always)
        func raw(_ y: Int) -> UnsafeMutableRawPointer {
            base.advanced(by: y * rowBytes)
        }

        @inline(__always)
        func bgra(_ y: Int) -> UnsafeMutablePointer<UInt32> {
            raw(y).assumingMemoryBound(to: UInt32.self)
        }
    }

    /// Everything one band of rows needs, grouped so the row loop takes two
    /// arguments instead of six.
    private struct Pass {
        let source: Plane
        let display: Plane
        let width: Int
        let expand: UnsafeBufferPointer<UInt16>
        let matrix: WireYCbCr

        /// One pixel as the display buffer holds it: the matrix onto the wire's
        /// own R'G'B' scale, then the shared levels table, then down to the 8
        /// bits BGRA holds.
        @inline(__always)
        func bgra(luma: Int, chroma: (cb: Int, cr: Int)) -> UInt32 {
            let rgb = matrix.rgb(luma: luma, cb: chroma.cb, cr: chroma.cr)
            // BGRA little-endian as one 32-bit store
            return UInt32(expand[rgb.b] >> 2)
                | (UInt32(expand[rgb.g] >> 2) << 8)
                | (UInt32(expand[rgb.r] >> 2) << 16)
                | 0xFF00_0000
        }
    }

    /// Scratch per band: the twelve components of a block, then the four chroma
    /// pairs those six pixels interpolate between (this block's three plus the
    /// first pair of the next one).
    private static let scratchCount =
        V210Packing.blockComponents + 2 * (V210Packing.blockChromaPairs + 1)

    /// One band's worth of rows. Runs on a `concurrentPerform` worker: `rows` is
    /// this band's disjoint range and the table is read-only for the pass.
    ///
    /// The scratch is allocated ONCE per band and reused by every block of every
    /// row in it — per-block allocation would cost more than the unpack.
    private static func convertRows(_ rows: Range<Int>, _ pass: Pass) {
        withUnsafeTemporaryAllocation(
            of: UInt16.self, capacity: scratchCount
        ) { scratch in
            guard let components = scratch.baseAddress else { return }
            for y in rows {
                convertRow(y, pass, components)
            }
        }
    }

    /// One row: walk it a block of six pixels at a time.
    private static func convertRow(_ y: Int, _ pass: Pass,
                                   _ components: UnsafeMutablePointer<UInt16>) {
        let source = UnsafeRawPointer(pass.source.raw(y))
        let display = pass.display.bgra(y)
        let chroma = components + V210Packing.blockComponents
        var x = 0
        while x < pass.width {
            let block = source + (x / V210Packing.blockPixels)
                * V210Packing.blockBytes
            V210Packing.unpackBlock(block, into: components)
            let hasNext = x + V210Packing.blockPixels < pass.width
            fillChroma(chroma, components: components,
                       nextBlock: hasNext
                           ? block + V210Packing.blockBytes : nil,
                       firstPixel: x, width: pass.width)
            // a width that is not a multiple of six leaves a partial block: the
            // bytes are all there (the stride was checked) and only the pixels
            // past the frame edge are skipped
            let count = min(V210Packing.blockPixels, pass.width - x)
            for index in 0..<count {
                display[x + index] = pass.bgra(
                    luma: Int(components[V210Packing.lumaSlot(index)]),
                    chroma: upsampled(chroma, at: index))
            }
            x += V210Packing.blockPixels
        }
    }

    /// The four chroma pairs this block's six pixels interpolate between: its
    /// own three, plus the first pair of the NEXT block, which is what its last
    /// odd pixel needs.
    ///
    /// Pairs that lie past the frame's right edge repeat the last real one. That
    /// covers both edges the format has — the final pixel of a row, whose
    /// right-hand neighbour does not exist, and a partial trailing block, whose
    /// remaining pairs are padding. The padding bytes are inside the row and
    /// safe to read, but they are not picture: averaging into them would tint
    /// the right-hand column with whatever the board left there.
    @inline(__always)
    private static func fillChroma(_ chroma: UnsafeMutablePointer<UInt16>,
                                   components: UnsafeMutablePointer<UInt16>,
                                   nextBlock: UnsafeRawPointer?,
                                   firstPixel: Int, width: Int) {
        for pair in 0..<V210Packing.blockChromaPairs {
            chroma[pair * 2] = components[V210Packing.cbSlot(pair)]
            chroma[pair * 2 + 1] = components[V210Packing.crSlot(pair)]
        }
        if let nextBlock {
            let last = V210Packing.blockChromaPairs
            chroma[last * 2] =
                UInt16(V210Packing.component(nextBlock, V210Packing.cbSlot(0)))
            chroma[last * 2 + 1] =
                UInt16(V210Packing.component(nextBlock, V210Packing.crSlot(0)))
        }
        // Every pair whose own (even) pixel is outside the frame — including the
        // borrowed one when there is no next block — repeats its predecessor.
        for pair in 1...V210Packing.blockChromaPairs
        where firstPixel + pair * 2 >= width {
            chroma[pair * 2] = chroma[pair * 2 - 2]
            chroma[pair * 2 + 1] = chroma[pair * 2 - 1]
        }
    }

    /// Chroma for pixel `p` of a block — the upsample, and the one place this
    /// converter makes a choice the RGB paths never have to.
    ///
    /// 4:2:2 chroma is CO-SITED with the even luma of each pair, so an even
    /// pixel takes its coded sample exactly as it arrived and only the odd
    /// pixels are interpolated: the midpoint of the pairs either side of them,
    /// which is linear interpolation at the one position that needs it.
    ///
    /// Nearest (replicating the pair across both pixels) was the alternative and
    /// it is visibly wrong on the instrument this app ships: a colour edge
    /// becomes a two-pixel staircase, and on a vectorscope the transitional
    /// samples that should trace a line between two patches sit in one of the
    /// two boxes instead. It costs one add and one shift per chroma component of
    /// every odd pixel, plus one extra unaligned word load per six-pixel block
    /// to reach the next block's pair — measured at 1080p in
    /// `ScopePerformanceTests`, and the whole split still runs in a small
    /// fraction of a frame interval.
    ///
    /// The RECORD path does not resample chroma at all: it is the wire frame.
    /// The scopes do not interpolate either, on purpose — see
    /// `V210Packing.pixel`.
    @inline(__always)
    private static func upsampled(_ chroma: UnsafeMutablePointer<UInt16>,
                                  at p: Int) -> (cb: Int, cr: Int) {
        let pair = p >> 1
        guard p & 1 == 1 else {
            return (Int(chroma[pair * 2]), Int(chroma[pair * 2 + 1]))
        }
        return ((Int(chroma[pair * 2]) + Int(chroma[pair * 2 + 2]) + 1) >> 1,
                (Int(chroma[pair * 2 + 1]) + Int(chroma[pair * 2 + 3]) + 1) >> 1)
    }
}
