@preconcurrency import Accelerate
@preconcurrency import CoreVideo
import Foundation

/// The one operation that turns studio-swing code values into a picture, on
/// 8-bit BGRA.
///
/// It exists as a type of its own because it now runs in two places that must
/// not disagree by a code: on the live wire (`CapturePipeline`) and on the app's
/// own recordings coming back out of the decoder (`PlaybackFrameTap`) — a take
/// under review has to look like the monitor looked while it was recorded, and
/// two copies of a table is how that stops being true.
///
/// Defined on gamma-encoded code values, so it runs on raw bytes: a CIColorMatrix
/// in CoreImage's linear working space crushes shadows and dulls highlights.
public enum StudioSwing {
    /// Nominal black 16 onto 0 and nominal white 235 onto 255, clipped either
    /// side. Built once at first use — a table per frame is 256 divisions on
    /// the capture queue for a value that never changes.
    public static let expansionTable: [UInt8] = {
        let window = InputLevels.limited.eightBitWindow
        let span = Double(window.white - window.black)
        return (0...255).map {
            UInt8(min(255, max(0, Int(Double($0 - window.black) * 255 / span
                                      + 0.5))))
        }
    }()

    /// Alpha is not a level: the lookup leaves it alone.
    static let identityTable: [UInt8] = (0...255).map { UInt8($0) }

    /// The table a DECODED take needs to look like the monitor did while it was
    /// recorded, for a file that is `wireCodes` studio swing and encoded with
    /// `transfer`. nil when neither applies, which is every SDR take that has
    /// no levels key — i.e. every YCbCr take there has ever been.
    ///
    /// The two operations are composed into ONE table rather than applied one
    /// after the other. Not for speed: two passes over a UHD frame would also
    /// be two roundings, and the second one would be rounding a value the first
    /// one had already quantized. One table is one rounding, from the code the
    /// decoder gave to the code the screen gets.
    public static func playbackTable(wireCodes: Bool,
                                     transfer: SignalTransfer) -> [UInt8]? {
        guard wireCodes || transfer.isHDR else { return nil }
        let swing = wireCodes ? expansionTable : identityTable
        guard transfer.isHDR else { return swing }
        let tone = toneTable(for: transfer)
        return swing.map { tone[Int($0)] }
    }

    /// wire level (0…255, the scale the decoder hands back) → the tone-mapped
    /// display value, through the same `HDRTransfer` the live path uses.
    ///
    /// Measured: a v210 ProRes file tagged PQ decodes to BGRA with its codes
    /// merely video-range expanded — AVFoundation does not tone map on the way
    /// out, and the PQ tag changes nothing about the pixels it returns. So the
    /// app has to do it, and doing it from the decoder's own 8-bit output is
    /// exact enough to land within a code or two of the live display table
    /// (`PlaybackLevelsParityTests`).
    static func toneTable(for transfer: SignalTransfer) -> [UInt8] {
        (0...255).map { code in
            let display = transfer.displaySignal(forSignal: Double(code) / 255)
            return UInt8(min(255, max(0, Int(display * 255 + 0.5))))
        }
    }

    /// Expand `source` into `destination`; pass the same buffer for both to do
    /// it in place. False when either buffer is not 32BGRA or cannot be
    /// addressed, in which case nothing has been written.
    ///
    /// In place is right for a frame the caller owns outright (the capture
    /// path allocates its own). It is wrong for anything a decoder handed over:
    /// those buffers can share an IOSurface with the frame the decoder is still
    /// holding, so the playback side expands into a pooled copy.
    @discardableResult
    public static func expand(_ source: CVPixelBuffer,
                              into destination: CVPixelBuffer) -> Bool {
        map(source, into: destination, table: expansionTable)
    }

    /// The same byte lookup for ANY 256-entry table.
    ///
    /// Extracted because playback of an HDR take needs a second one: the
    /// decoder hands back the wire's codes on an SDR scale, and the tone map
    /// that puts them where the live monitor put them is also a function of one
    /// byte. Two lookups composed into one table is one pass, and it keeps the
    /// rule that a frame is levelled exactly once.
    @discardableResult
    public static func map(_ source: CVPixelBuffer,
                           into destination: CVPixelBuffer,
                           table: [UInt8]) -> Bool {
        guard table.count == 256 else { return false }
        let inPlace = source === destination
        guard CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetPixelFormatType(destination)
                == kCVPixelFormatType_32BGRA
        else { return false }
        CVPixelBufferLockBaseAddress(source, inPlace ? [] : .readOnly)
        if !inPlace { CVPixelBufferLockBaseAddress(destination, []) }
        defer {
            CVPixelBufferUnlockBaseAddress(source, inPlace ? [] : .readOnly)
            if !inPlace { CVPixelBufferUnlockBaseAddress(destination, []) }
        }
        guard let sourceBase = CVPixelBufferGetBaseAddress(source),
              let destinationBase = CVPixelBufferGetBaseAddress(destination)
        else { return false }
        let width = min(CVPixelBufferGetWidth(source),
                        CVPixelBufferGetWidth(destination))
        let height = min(CVPixelBufferGetHeight(source),
                         CVPixelBufferGetHeight(destination))
        var input = vImage_Buffer(data: sourceBase,
                                  height: vImagePixelCount(height),
                                  width: vImagePixelCount(width),
                                  rowBytes: CVPixelBufferGetBytesPerRow(source))
        var output = vImage_Buffer(
            data: destinationBase, height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: CVPixelBufferGetBytesPerRow(destination))
        // byte order is B G R A: remap the three color channels, keep alpha
        let error = table.withUnsafeBufferPointer { lut in
            identityTable.withUnsafeBufferPointer { identity in
                vImageTableLookUp_ARGB8888(&input, &output,
                                           lut.baseAddress!, lut.baseAddress!,
                                           lut.baseAddress!, identity.baseAddress!,
                                           vImage_Flags(kvImageNoFlags))
            }
        }
        return error == kvImageNoError
    }
}
