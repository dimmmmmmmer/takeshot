@preconcurrency import AVFoundation
@preconcurrency import CoreVideo
import Foundation

/// Single source of truth for the colorimetry presets ("709" / "601" / "2020"
/// / "pq" / "hlg"). Both consumers derive from the same table: TakeWriter
/// (AVVideo* keys in the file) and CapturePipeline (kCVImageBuffer* attachments
/// on live buffers) — previously two hand-maintained switches that had drifted
/// apart.
///
/// The last two are not operator settings and never appear in the Settings
/// picker: they are what a PQ or HLG SOURCE forces on the file it is recorded
/// into (see `WireColorimetry.filePreset`). They live in this table rather than
/// beside the writer for exactly the reason the other three do — a second place
/// that decides what a tag says is a second place for it to drift.
public enum ColorTags {
    /// The three preset spellings the app names in code rather than in a
    /// picker. Stated once so a typo cannot make a file claim SDR.
    public static let rec2020Preset = "2020"
    public static let pqPreset = "pq"
    public static let hlgPreset = "hlg"

    public struct Values {
        /// CVPixelBuffer attachment values (preview/pipeline).
        public let cvPrimaries: CFString
        public let cvTransfer: CFString
        public let cvMatrix: CFString
        /// AVVideoColorProperties values (recorded file).
        public let avPrimaries: String
        public let avTransfer: String
        public let avMatrix: String
    }

    /// Resolve a preset (nil → "709"). For 2020 SDR both sides use the 709
    /// transfer curve: AVFoundation has no 2020-SDR transfer constant, and
    /// tagging the buffers the same way keeps file and preview identical.
    ///
    /// "2020" is ALSO what an HDR frame's display buffer is tagged with, and
    /// for the same reason one sentence up: that buffer has been tone mapped
    /// into an SDR transfer but its primaries are still the camera's, so
    /// Rec.2020 primaries with a Rec.709 curve is not an approximation there —
    /// it is literally what the buffer holds.
    public static func values(for preset: String?) -> Values {
        switch preset {
        case pqPreset:
            // PQ takes Rec.2020 primaries by BT.2100; a PQ signal on Rec.709
            // primaries is not a thing any camera sends.
            return Values(
                cvPrimaries: kCVImageBufferColorPrimaries_ITU_R_2020,
                cvTransfer: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
                cvMatrix: kCVImageBufferYCbCrMatrix_ITU_R_2020,
                avPrimaries: AVVideoColorPrimaries_ITU_R_2020,
                avTransfer: AVVideoTransferFunction_SMPTE_ST_2084_PQ,
                avMatrix: AVVideoYCbCrMatrix_ITU_R_2020)
        case hlgPreset:
            return Values(
                cvPrimaries: kCVImageBufferColorPrimaries_ITU_R_2020,
                cvTransfer: kCVImageBufferTransferFunction_ITU_R_2100_HLG,
                cvMatrix: kCVImageBufferYCbCrMatrix_ITU_R_2020,
                avPrimaries: AVVideoColorPrimaries_ITU_R_2020,
                avTransfer: AVVideoTransferFunction_ITU_R_2100_HLG,
                avMatrix: AVVideoYCbCrMatrix_ITU_R_2020)
        case "601":
            return Values(
                cvPrimaries: kCVImageBufferColorPrimaries_SMPTE_C,
                cvTransfer: kCVImageBufferTransferFunction_ITU_R_709_2,
                cvMatrix: kCVImageBufferYCbCrMatrix_ITU_R_601_4,
                avPrimaries: AVVideoColorPrimaries_SMPTE_C,
                avTransfer: AVVideoTransferFunction_ITU_R_709_2,
                avMatrix: AVVideoYCbCrMatrix_ITU_R_601_4)
        case rec2020Preset:
            return Values(
                cvPrimaries: kCVImageBufferColorPrimaries_ITU_R_2020,
                cvTransfer: kCVImageBufferTransferFunction_ITU_R_709_2,
                cvMatrix: kCVImageBufferYCbCrMatrix_ITU_R_2020,
                avPrimaries: AVVideoColorPrimaries_ITU_R_2020,
                avTransfer: AVVideoTransferFunction_ITU_R_709_2,
                avMatrix: AVVideoYCbCrMatrix_ITU_R_2020)
        default:
            return Values(
                cvPrimaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
                cvTransfer: kCVImageBufferTransferFunction_ITU_R_709_2,
                cvMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                avPrimaries: AVVideoColorPrimaries_ITU_R_709_2,
                avTransfer: AVVideoTransferFunction_ITU_R_709_2,
                avMatrix: AVVideoYCbCrMatrix_ITU_R_709_2)
        }
    }

    /// AVVideoColorPropertiesKey dictionary for the recorded file.
    public static func videoColorProperties(for preset: String?) -> [String: String] {
        let v = values(for: preset)
        return [AVVideoColorPrimariesKey: v.avPrimaries,
                AVVideoTransferFunctionKey: v.avTransfer,
                AVVideoYCbCrMatrixKey: v.avMatrix]
    }

    /// Stamp a pixel buffer with the preset's colorimetry attachments.
    /// NOTE: full-range BGRA must not be handed to AVSampleBufferDisplayLayer
    /// directly regardless of tags — the display path renders it with a
    /// video-range squeeze (washed blacks). The pipeline converts preview
    /// frames to 2vuy first (see CapturePipeline.previewBuffer).
    public static func tag(_ pixelBuffer: CVPixelBuffer, preset: String?) {
        let v = values(for: preset)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey,
                              v.cvPrimaries, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey,
                              v.cvTransfer, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey,
                              v.cvMatrix, .shouldPropagate)
    }
}
