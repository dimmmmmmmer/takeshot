@preconcurrency import CoreVideo
import Foundation

/// Converter for 10-bit RGB capture ('r210', big-endian 2:10:10:10 as the
/// board delivers it). One pass produces both products the pipeline needs:
///
/// - a full-range 8-bit BGRA **display** buffer (preview/LUT/scopes/grabs
///   keep their existing 8-bit path), and
/// - a **record** r210 buffer precompensated for VideoToolbox's convention:
///   VT interprets r210 content as video-range RGB 64–960 and expands it to
///   full scale inside the codec (measured — see the docs in the repo), so we
///   map our intended full-range values into that window. The decoded file
///   then comes back to the intended values within ±1 in 10-bit units,
///   unbiased — versus the systematic +0.4 8-bit codes of the BGRA path that
///   steep viewing LUTs amplified into a visible lift.
///
/// Levels follow the same policy as the 8-bit path, and the SAME three-way
/// choice: `full` passes wire codes through, `limited` expands 64–940 onto the
/// full scale and clamps everything outside it, and
/// `limitedPreservingExcursions` expands the camera's whole legal swing
/// 4–1019 instead, so no code is destroyed on the way to either product.
///
/// The expansion is one table either way — the mode picks its two ends. That
/// matters for the recorded file as much as for the screen: `precomp` is built
/// FROM the expanded value, so a code the expansion clamps is gone from the
/// file too, not just from the preview.
public final class TenBitConverter {
    public static let r210 = OSType(0x7232_3130) // 'r210'

    /// wire code (0…1023) → intended full-range value.
    private var expand = [UInt16](repeating: 0, count: 1024)
    /// wire code → VT-coded record value (precompensated).
    private var precomp = [UInt16](repeating: 0, count: 1024)
    private var levels = InputLevels.limited

    private let displayPool = PixelBufferPool()
    private let recordPool = PixelBufferPool(format: TenBitConverter.r210)

    public init() {
        rebuildTables()
    }

    /// `limited` mirrors the 8-bit levels setting (auto → limited for RGB444).
    /// Kept because it says exactly what the two original modes were; the
    /// three-way form below is what the pipeline calls.
    public func setLimitedRange(_ limited: Bool) {
        setLevels(limited ? .limited : .full)
    }

    /// The resolved input-levels mode for the current source.
    public func setLevels(_ newLevels: InputLevels) {
        guard newLevels != levels else { return }
        levels = newLevels
        rebuildTables()
    }

    private func rebuildTables() {
        let window = levels.wireWindow
        let span = Double(window.white - window.black)
        for code in 0..<1024 {
            let full = levels == .full ? code
                : min(1023, max(0, Int((Double(code - window.black)) * 1023
                                       / span + 0.5)))
            expand[code] = UInt16(full)
            // VT window: video-range RGB 64–960 expands to 0–1023 in the codec
            precomp[code] = UInt16(64 + Int(Double(full) * 896 / 1023 + 0.5))
        }
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
            precomp.withUnsafeBufferPointer { precompTable in
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
