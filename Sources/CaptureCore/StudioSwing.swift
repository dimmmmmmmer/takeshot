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
        let error = expansionTable.withUnsafeBufferPointer { lut in
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
