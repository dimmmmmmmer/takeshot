@preconcurrency import CoreVideo
import Foundation

/// Converter for 10-bit RGB capture ('r210', big-endian 2:10:10:10 as the
/// board delivers it). One pass produces both products the pipeline needs,
/// and they answer to DIFFERENT rules — the picture and the deliverable want
/// opposite things from the same wire codes:
///
/// - a full-range 8-bit BGRA **display** buffer (preview/LUT/scopes/grabs),
///   expanded on the nominal pair for the levels mode: studio swing puts 64 on
///   0 and 940 on 1023 and clips the excursions, so black is black on the
///   monitor;
/// - a **record** r210 buffer carrying the WIRE codes — every code the camera
///   sent, footroom and headroom included, with no expansion of any kind
///   applied to the picture. It is precompensated for VideoToolbox's measured
///   convention and nothing else: VT reads r210 content as video-range RGB
///   64–960 and expands it to full scale inside the codec, so the wire code is
///   mapped into that window and the decoded file gives it back within ±1 in
///   10-bit units, unbiased.
///
/// The two tables are therefore built from different inputs, and that is the
/// whole design: `expand` from the levels mode, `precomp` from the wire code
/// alone. `precomp` used to be built FROM the expanded value, which meant a
/// display decision reached the deliverable — clip the excursions for the
/// monitor and they were gone from the file as well.
///
/// A file written this way carries studio-swing codes, so the app expands it
/// again on the way back out (see `TakeWriter.levelsKey`): playback of a take
/// shows exactly what the monitor showed while it was recorded.
///
/// `TwelveBitConverter` is the 'R12B' sibling. The display half of the policy
/// is shared with it (`WireDisplayTable`); the record half cannot be, because
/// the two record formats have different measured VideoToolbox conventions —
/// see that type for the numbers.
public final class TenBitConverter: WireConverter {
    public static let r210 = OSType(0x7232_3130) // 'r210'

    public var wireFormat: OSType { Self.r210 }
    public var recordPixelFormat: OSType { Self.r210 }
    /// 'r210' is 32 bits per pixel, the same as the BGRA display buffer.
    public var recordBytesPerPixel: Int { 4 }

    /// wire code (0…1023) → the value that appears on the DISPLAY.
    private var expand = WireDisplayTable.expand(levels: .limited, bits: 10)
    /// wire code → the r210 value to hand the encoder so that the decoded file
    /// returns that same wire code. Free of the levels mode by construction:
    /// the file carries what the camera sent, whatever the monitor is doing.
    private static let precomp: [UInt16] = (0..<1024).map { code in
        // VT window: video-range RGB 64–960 expands to 0–1023 in the codec
        UInt16(64 + Int(Double(code) * 896 / 1023 + 0.5))
    }
    private var levels = InputLevels.limited

    private let displayPool = PixelBufferPool()
    private let recordPool = PixelBufferPool(format: TenBitConverter.r210)

    public init() {}

    /// `limited` mirrors the 8-bit levels setting (auto → limited for RGB444).
    /// Kept because it says exactly what the choice is; the named form below is
    /// what the pipeline calls.
    public func setLimitedRange(_ limited: Bool) {
        setLevels(limited ? .limited : .full)
    }

    /// The resolved input-levels mode for the current source.
    /// Only the display table has a mode to rebuild for; the record table is a
    /// constant, which is the same statement as "levels never reach the file".
    public func setLevels(_ newLevels: InputLevels) {
        guard newLevels != levels else { return }
        levels = newLevels
        expand = WireDisplayTable.expand(levels: newLevels, bits: 10)
    }

    /// Split an r210 wire frame into (display BGRA8, record r210).
    /// Runs on the pipeline queue; ~11 ms for UHD single-threaded.
    public func convert(_ source: CVPixelBuffer)
        -> (display: CVPixelBuffer, record: CVPixelBuffer)? {
        guard CVPixelBufferGetPixelFormatType(source) == Self.r210
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
              let recordBase = CVPixelBufferGetBaseAddress(record) else { return nil }
        // nonisolated(unsafe): the bands below run concurrently over these
        // pointers, and that is safe by construction — each band owns a disjoint
        // range of rows and the two tables are read-only for the whole pass.
        nonisolated(unsafe) let sb = sourceBase
        nonisolated(unsafe) let db = displayBase
        nonisolated(unsafe) let rb = recordBase
        let sbpr = CVPixelBufferGetBytesPerRow(source)
        let dbpr = CVPixelBufferGetBytesPerRow(display)
        let rbpr = CVPixelBufferGetBytesPerRow(record)
        // rows are independent and the tables are read-only: split into bands
        // (~11 ms single-threaded at UHD → ~2-3 ms) so the pipeline queue gets
        // its frame budget back
        let bands = min(8, max(1, height / 270))
        expand.withUnsafeBufferPointer { expandTable in
            Self.precomp.withUnsafeBufferPointer { precompTable in
                // read-only for the whole pass — see the note above
                nonisolated(unsafe) let exp = expandTable
                nonisolated(unsafe) let pre = precompTable
                // the type is named in full: `Self` inside a closure reads as a
                // capture of the instance, and nothing here may retain it
                DispatchQueue.concurrentPerform(iterations: bands) { band in
                    // the Pass is built HERE, from the values the closure
                    // already captures — it is never captured itself
                    TenBitConverter.convertRows(
                        (band * height / bands)..<((band + 1) * height / bands),
                        Pass(source: Plane(base: sb, rowBytes: sbpr),
                             display: Plane(base: db, rowBytes: dbpr),
                             record: Plane(base: rb, rowBytes: rbpr),
                             width: width, expand: exp, precomp: pre))
                }
            }
        }
        return (display, record)
    }

    /// One locked buffer as the row loop sees it: base address and row stride.
    private struct Plane {
        let base: UnsafeMutableRawPointer
        let rowBytes: Int

        /// r210 and BGRA are both 32 bits per pixel, so every plane here is
        /// addressed as words.
        func row(_ y: Int) -> UnsafeMutablePointer<UInt32> {
            base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt32.self)
        }
    }

    /// Everything one band of rows needs. Grouped into a value so the row loop
    /// takes two arguments instead of eight.
    private struct Pass {
        let source: Plane
        let display: Plane
        let record: Plane
        let width: Int
        let expand: UnsafeBufferPointer<UInt16>
        let precomp: UnsafeBufferPointer<UInt16>
    }

    /// One band's worth of rows, split out of `convert` so the setup above
    /// stays readable. Runs on a concurrentPerform worker: `rows` is this
    /// band's disjoint range and the two tables are read-only for the pass.
    private static func convertRows(_ rows: Range<Int>, _ pass: Pass) {
        for y in rows {
            let srow = pass.source.row(y)
            let drow = pass.display.row(y)
            let rrow = pass.record.row(y)
            for x in 0..<pass.width {
                let word = UInt32(bigEndian: srow[x])
                let r = Int((word >> 20) & 0x3FF)
                let g = Int((word >> 10) & 0x3FF)
                let b = Int(word & 0x3FF)
                // BGRA little-endian as one 32-bit store
                drow[x] = UInt32(pass.expand[b] >> 2)
                    | (UInt32(pass.expand[g] >> 2) << 8)
                    | (UInt32(pass.expand[r] >> 2) << 16)
                    | 0xFF00_0000
                rrow[x] = ((UInt32(pass.precomp[r]) << 20)
                    | (UInt32(pass.precomp[g]) << 10)
                    | UInt32(pass.precomp[b])).bigEndian
            }
        }
    }
}
