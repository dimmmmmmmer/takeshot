@preconcurrency import CoreVideo
import Foundation

/// Converter for 12-bit RGB capture (`'R12B'`, `bmdFormat12BitRGB` — eight
/// pixels packed big-endian into 36 bytes; see `R12BPacking`).
///
/// The 10-bit sibling of this type is `TenBitConverter`, and the two answer to
/// the same rule: one pass over the wire frame produces exactly two products,
/// from two different tables, because the picture and the deliverable want
/// opposite things from the same codes.
///
/// - a full-range 8-bit BGRA **display** buffer, expanded on the NOMINAL pair
///   for the levels mode — at 12 bits that pair is 256 and 3760, which is the
///   same fraction of the scale as 64/940 is at 10, so a 12-bit source's black
///   lands exactly where a 10-bit source's does. The table comes from
///   `WireDisplayTable`, shared with the 10-bit path so the two cannot drift.
/// - a **record** buffer carrying the WIRE codes, every code the camera sent.
///
/// The record product is where this path is genuinely better than the 10-bit
/// one, and it is worth stating why. `TenBitConverter` has to precompensate:
/// VideoToolbox reads `'r210'` as video-range RGB 64–960 and expands it inside
/// the codec, and it CLAMPS outside that window, so the 10-bit file is
/// wire-referred rather than wire-exact. The 12-bit record buffer is
/// `kCVPixelFormatType_64RGBALE` — 16-bit little-endian RGBA — and VideoToolbox
/// treats that as FULL range. Measured through a real ProRes 4444 encode and
/// decode: no window, no clamp, no precompensation, and codes 0 and 4095 come
/// back as 0 and 4095. So the record table here is the identity, `code << 4`,
/// and that is not laziness — it is the measurement.
///
/// Because the file still carries studio-swing CODES (the wire's, unexpanded),
/// the take is tagged `com.takeshot.levels = "wire"` exactly as a 10-bit take
/// is, and playback expands it the same way: 12-bit studio swing 256/3760 is
/// 16/235 in the 8 bits the player works in, so `PlaybackFrameTap+Levels`
/// needs no 12-bit case at all.
public final class TwelveBitConverter: WireConverter {
    /// `'R12B'`.
    public static let r12b = R12BPacking.pixelFormat
    /// 16-bit little-endian RGBA. Chosen by measurement over the alternatives:
    /// `kCVPixelFormatType_48RGB` ('b48r') is REFUSED by the ProRes encoder
    /// (-12905 at finish), and `kCVPixelFormatType_64ARGB` ('b64a') round-trips
    /// identically but needs a byte swap per component on a little-endian host.
    public static let record64RGBALE = kCVPixelFormatType_64RGBALE

    public var wireFormat: OSType { Self.r12b }
    public var recordPixelFormat: OSType { Self.record64RGBALE }
    /// 8 bytes a pixel, against 4 for BGRA and 'r210'. The pre-roll ring is
    /// sized from this — a 3 s lead at UHD is twice the RAM it is at 10 bits,
    /// and the ring's memory cap has to know that or it overshoots its budget.
    public var recordBytesPerPixel: Int { 8 }
    /// Yes, exactly as for 'r210': the file carries the wire's studio-swing
    /// CODES and no RGB coded picture can say so on its own. 12-bit swing
    /// 256/3760 is 16/235 in the 8 bits the player works in, so the existing
    /// playback table needs no 12-bit case.
    public var recordNeedsPlaybackExpansion: Bool { true }

    /// wire code (0…4095) → the value that appears on the DISPLAY.
    private var expand = WireDisplayTable.expand(levels: .limited, bits: 12)
    private var levels = InputLevels.limited

    private let displayPool = PixelBufferPool()
    private let recordPool =
        PixelBufferPool(format: TwelveBitConverter.record64RGBALE)

    public init() {}

    /// The resolved input-levels mode for the current source. Only the display
    /// table has a mode to rebuild for; the record product is the wire, which
    /// is the same statement as "levels never reach the file".
    public func setLevels(_ newLevels: InputLevels) {
        guard newLevels != levels else { return }
        levels = newLevels
        expand = WireDisplayTable.expand(levels: newLevels, bits: 12)
    }

    /// Split an 'R12B' wire frame into (display BGRA8, record 64RGBALE).
    /// Runs on the pipeline queue, banded across cores like the 10-bit path.
    public func convert(_ source: CVPixelBuffer)
        -> (display: CVPixelBuffer, record: CVPixelBuffer)? {
        guard CVPixelBufferGetPixelFormatType(source) == Self.r12b
        else { return nil }
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        guard let display = displayPool.buffer(width: width, height: height),
              let record = recordPool.buffer(width: width, height: height)
        else { return nil }
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(display, [])
        CVPixelBufferLockBaseAddress(record, [])
        defer {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
            CVPixelBufferUnlockBaseAddress(display, [])
            CVPixelBufferUnlockBaseAddress(record, [])
        }
        guard let sourceBase = CVPixelBufferGetBaseAddress(source),
              let displayBase = CVPixelBufferGetBaseAddress(display),
              let recordBase = CVPixelBufferGetBaseAddress(record)
        else { return nil }
        let sbpr = CVPixelBufferGetBytesPerRow(source)
        // A short row would make the last block read past its end. Refusing the
        // frame drops it visibly (the pipeline counts it) instead of unpacking
        // whatever follows the row into the picture.
        guard sbpr >= R12BPacking.blockRowBytes(width: width) else { return nil }
        // nonisolated(unsafe): the bands below run concurrently over these
        // pointers, and that is safe by construction — each band owns a
        // disjoint range of rows and the table is read-only for the whole pass.
        nonisolated(unsafe) let sb = sourceBase
        nonisolated(unsafe) let db = displayBase
        nonisolated(unsafe) let rb = recordBase
        let dbpr = CVPixelBufferGetBytesPerRow(display)
        let rbpr = CVPixelBufferGetBytesPerRow(record)
        let bands = min(8, max(1, height / 270))
        expand.withUnsafeBufferPointer { expandTable in
            // read-only for the whole pass — see the note above
            nonisolated(unsafe) let exp = expandTable
            // the type is named in full: `Self` inside a closure reads as a
            // capture of the instance, and nothing here may retain it
            DispatchQueue.concurrentPerform(iterations: bands) { band in
                TwelveBitConverter.convertRows(
                    (band * height / bands)..<((band + 1) * height / bands),
                    Pass(source: Plane(base: sb, rowBytes: sbpr),
                         display: Plane(base: db, rowBytes: dbpr),
                         record: Plane(base: rb, rowBytes: rbpr),
                         width: width, expand: exp))
            }
        }
        return (display, record)
    }

    /// One locked buffer as the row loop sees it. Unlike the 10-bit path the
    /// three planes here have three different element widths — 36 bytes per 8
    /// source pixels, 4 bytes per display pixel, 8 per record pixel — so the
    /// row accessor is offered raw and typed rather than as words.
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

        @inline(__always)
        func rgba16(_ y: Int) -> UnsafeMutablePointer<UInt16> {
            raw(y).assumingMemoryBound(to: UInt16.self)
        }
    }

    /// Everything one band of rows needs, grouped so the row loop takes two
    /// arguments instead of seven.
    private struct Pass {
        let source: Plane
        let display: Plane
        let record: Plane
        let width: Int
        let expand: UnsafeBufferPointer<UInt16>
    }

    /// One band's worth of rows. Runs on a `concurrentPerform` worker: `rows`
    /// is this band's disjoint range and the table is read-only for the pass.
    ///
    /// The 24-component scratch is allocated ONCE per band and reused by every
    /// block of every row in it — per-block allocation would cost more than the
    /// unpack.
    private static func convertRows(_ rows: Range<Int>, _ pass: Pass) {
        withUnsafeTemporaryAllocation(
            of: UInt16.self, capacity: R12BPacking.blockComponents
        ) { scratch in
            guard let components = scratch.baseAddress else { return }
            for y in rows {
                convertRow(y, pass, components)
            }
        }
    }

    /// One row: walk it a block of eight pixels at a time.
    private static func convertRow(_ y: Int, _ pass: Pass,
                                   _ components: UnsafeMutablePointer<UInt16>) {
        let source = UnsafeRawPointer(pass.source.raw(y))
        let display = pass.display.bgra(y)
        let record = pass.record.rgba16(y)
        var x = 0
        var block = 0
        while x < pass.width {
            R12BPacking.unpackBlock(
                source + block * R12BPacking.blockBytes, into: components)
            // a width that is not a multiple of eight leaves a partial block:
            // the bytes are all there (the stride was checked) and only the
            // pixels past the frame edge are skipped
            let count = min(R12BPacking.blockPixels, pass.width - x)
            for index in 0..<count {
                emit(pixel: x + index, components: components + index * 3,
                     display: display, record: record, expand: pass.expand)
            }
            x += R12BPacking.blockPixels
            block += 1
        }
    }

    /// One pixel into both products.
    ///
    /// Display: the levels table, then down to the 8 bits BGRA holds.
    /// Record: the wire code in the top 12 bits of a 16-bit component, which is
    /// what VideoToolbox hands back unchanged (measured), plus an opaque alpha —
    /// ProRes 4444 carries one and a constant plane costs it almost nothing.
    @inline(__always)
    private static func emit(pixel: Int,
                             components: UnsafeMutablePointer<UInt16>,
                             display: UnsafeMutablePointer<UInt32>,
                             record: UnsafeMutablePointer<UInt16>,
                             expand: UnsafeBufferPointer<UInt16>) {
        let r = Int(components[0]), g = Int(components[1]), b = Int(components[2])
        // BGRA little-endian as one 32-bit store
        display[pixel] = UInt32(expand[b] >> 4)
            | (UInt32(expand[g] >> 4) << 8)
            | (UInt32(expand[r] >> 4) << 16)
            | 0xFF00_0000
        let offset = pixel * 4
        record[offset] = UInt16(r << 4)
        record[offset + 1] = UInt16(g << 4)
        record[offset + 2] = UInt16(b << 4)
        record[offset + 3] = 0xFFFF
    }
}
