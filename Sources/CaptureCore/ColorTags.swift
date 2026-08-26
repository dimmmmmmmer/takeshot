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

    // MARK: - reading the tags back off a file
    //
    // The inverse of everything above, and it lives here for the reason the
    // writing half does: a second place that decides what a tag MEANS is a
    // second place for it to drift. There are two readers now — the player
    // (`PlaybackFrameTap+Levels`) and the dailies transcode — and they have to
    // reach the same answer about the same file, or a proxy disagrees with the
    // review it was made from.
    //
    // Anything that is not PQ or HLG is `.sdr` and anything that is not
    // Rec.2020 is `.rec709`. That is what leaves a foreign clip, a still and a
    // take from before these tags existed exactly as they are: a file that
    // states nothing gets no transform, rather than a guess.

    /// The transfer a `kCMFormatDescriptionExtension_TransferFunction` value
    /// names; `.sdr` for every other spelling and for none at all.
    static func transfer(ofTag tag: String?) -> SignalTransfer {
        let pq: String =
            kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String
        let hlg: String =
            kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String
        switch tag {
        case pq: return .pq
        case hlg: return .hlg
        default: return .sdr
        }
    }

    /// The transfer AND the primaries of one video format description, which
    /// only ever travel together — a PQ curve on Rec.709 primaries and one on
    /// Rec.2020 primaries are not the same picture, and whoever acts on the
    /// curve has to know which.
    public static func colorimetry(of description: CMFormatDescription)
        -> WireColorimetry {
        let extensions = CMFormatDescriptionGetExtensions(description)
            as? [String: Any] ?? [:]
        let transferTag = extensions[
            kCMFormatDescriptionExtension_TransferFunction as String] as? String
        let primariesTag = extensions[
            kCMFormatDescriptionExtension_ColorPrimaries as String] as? String
        let wide = kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String
        return WireColorimetry(
            transfer: transfer(ofTag: transferTag),
            primaries: primariesTag == wide ? .rec2020 : .rec709)
    }

    /// The same question asked of a whole asset: its first video track's
    /// format description, or `.sdr` when it has neither.
    public static func colorimetry(of asset: AVAsset) async -> WireColorimetry {
        guard let track = try? await asset.tracks(ofType: .video).first,
              let description: CMFormatDescription =
                try? await track.load(.formatDescriptions).first
        else { return .sdr }
        return colorimetry(of: description)
    }
}
