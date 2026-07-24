import CoreVideo
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
/// Levels follow the same policy as the 8-bit path: limited sources
/// (64–940, the 10-bit equivalent of 16–235) are expanded to full range
/// once, on wire code values; full-range sources pass through.
public final class TenBitConverter {
    public static let r210 = OSType(0x7232_3130) // 'r210'

    /// wire code (0…1023) → intended full-range value.
    private var expand = [UInt16](repeating: 0, count: 1024)
    /// wire code → VT-coded record value (precompensated).
    private var precomp = [UInt16](repeating: 0, count: 1024)
    private var limitedRange = true

    private let displayPool = PixelBufferPool()
    private let recordPool = PixelBufferPool(format: TenBitConverter.r210)

    public init() {
        rebuildTables()
    }

    /// `limited` mirrors the 8-bit levels setting (auto → limited for RGB444).
    public func setLimitedRange(_ limited: Bool) {
        guard limited != limitedRange else { return }
        limitedRange = limited
        rebuildTables()
    }

    private func rebuildTables() {
        for code in 0..<1024 {
            let full: Int
            if limitedRange {
                full = min(1023, max(0, Int((Double(code) - 64) * 1023 / 876
                                            + 0.5)))
            } else {
                full = code
            }
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
        guard let sb = CVPixelBufferGetBaseAddress(source),
              let db = CVPixelBufferGetBaseAddress(display),
              let rb = CVPixelBufferGetBaseAddress(record) else { return nil }
        let sbpr = CVPixelBufferGetBytesPerRow(source)
        let dbpr = CVPixelBufferGetBytesPerRow(display)
        let rbpr = CVPixelBufferGetBytesPerRow(record)
        expand.withUnsafeBufferPointer { exp in
            precomp.withUnsafeBufferPointer { pre in
                for y in 0..<height {
                    let srow = sb.advanced(by: y * sbpr)
                        .assumingMemoryBound(to: UInt32.self)
                    let drow = db.advanced(by: y * dbpr)
                        .assumingMemoryBound(to: UInt8.self)
                    let rrow = rb.advanced(by: y * rbpr)
                        .assumingMemoryBound(to: UInt32.self)
                    for x in 0..<width {
                        let word = UInt32(bigEndian: srow[x])
                        let r = Int((word >> 20) & 0x3FF)
                        let g = Int((word >> 10) & 0x3FF)
                        let b = Int(word & 0x3FF)
                        let d = drow + x * 4
                        d[0] = UInt8(exp[b] >> 2)
                        d[1] = UInt8(exp[g] >> 2)
                        d[2] = UInt8(exp[r] >> 2)
                        d[3] = 255
                        rrow[x] = ((UInt32(pre[r]) << 20)
                            | (UInt32(pre[g]) << 10)
                            | UInt32(pre[b])).bigEndian
                    }
                }
            }
        }
        return (display, record)
    }
}
