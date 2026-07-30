@preconcurrency import Accelerate
@preconcurrency import CoreVideo
import Foundation
import os.log

/// How a wire frame's code values are interpreted: the input-levels decision,
/// the one operation that applies it, the 10-bit split that does its own, and the
/// colorimetry tags that say what the values mean.
///
/// Split out of `+Frame` (which decided) and `+Preview` (which applied) — the
/// expansion is documented as "the single levels operation in the pipeline" yet
/// sat in the display file while the record path went through it. Getting levels
/// applied twice is the failure mode this file exists to keep visible.
extension CapturePipeline {
    /// One frame after the levels stage: the 8-bit BGRA buffer everything
    /// downstream reads, plus the precompensated 10-bit record buffer when the
    /// wire carried r210 (nil for every other format).
    struct LevelledFrame {
        let display: CVPixelBuffer
        let tenBitRecord: CVPixelBuffer?
    }

    /// Levels and, for a 10-bit wire, the split into display + record buffers.
    /// nil means the converter could not produce a frame and this one is
    /// dropped — the same `guard` the inline code had.
    func levelledFrame(from pixelBuffer: CVPixelBuffer,
                       format: CaptureFormat) -> LevelledFrame? {
        let inputLevels = effectiveInputLevels(for: format)
        // 10-bit RGB wire ('r210'): one pass yields the full-range display
        // BGRA AND the precompensated 10-bit record buffer; levels are applied
        // inside the converter, so the 8-bit stage below must not run again
        if CVPixelBufferGetPixelFormatType(pixelBuffer) == TenBitConverter.r210 {
            tenBitConverter.setLimitedRange(inputLevels != "full")
            guard let split = tenBitConverter.convert(pixelBuffer) else { return nil }
            tagColorIfUntagged(split.display)
            return LevelledFrame(display: split.display, tenBitRecord: split.record)
        }
        let leveled = inputLevels == "limited"
            ? (expandLimitedRGB(pixelBuffer) ?? pixelBuffer)
            : pixelBuffer
        return LevelledFrame(display: leveled, tenBitRecord: nil)
    }

    /// The levels decision for this frame, logged whenever it changes.
    ///
    /// input levels: the setting states what the SOURCE carries on the wire.
    /// "limited" (16-235 RGB) is expanded once to the full-range BGRA the
    /// rest of the pipeline assumes; "full" passes through untouched (e.g.
    /// a playout device already set to Full output levels). auto (nil)
    /// assumes limited for RGB 4:4:4 HDMI (CTA-861 default). Conversion to
    /// legal-range YUV in the recorded file is the encoder's job — never
    /// done on pixels here, so it can't be applied twice.
    private func effectiveInputLevels(for format: CaptureFormat) -> String? {
        let inputLevels = levelsMode ?? (format.isRGB444 ? "limited" : nil)
        let effective = inputLevels ?? "passthrough"
        // one log line per decision change — settles "is expansion active" without
        // guessing (a stale-settings app instance once recorded an unexpanded take)
        if lastLoggedLevels != effective {
            lastLoggedLevels = effective
            os_log("levels: mode=%{public}s rgb444=%{public}d effective=%{public}s",
                   log: Self.levelsLog, type: .default,
                   levelsMode ?? "auto", format.isRGB444 ? 1 : 0, effective)
        }
        return inputLevels
    }

    /// Expand limited-range (16-235) RGB to full range, in place (vImage byte
    /// lookup — no CoreImage pass, no extra buffer). BGRA only: this is the
    /// single levels operation in the pipeline; the encoder handles full-RGB →
    /// legal-YUV for the file, and YUV sources are legal-range by definition.
    private func expandLimitedRGB(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA
        else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        var image = vImage_Buffer(
            data: base,
            height: vImagePixelCount(CVPixelBufferGetHeight(pixelBuffer)),
            width: vImagePixelCount(CVPixelBufferGetWidth(pixelBuffer)),
            rowBytes: CVPixelBufferGetBytesPerRow(pixelBuffer))
        // byte order is B G R A: remap the three color channels, keep alpha
        let error = Self.levelsExpandTable.withUnsafeBufferPointer { lut in
            Self.levelsTableIdentity.withUnsafeBufferPointer { identity in
                vImageTableLookUp_ARGB8888(&image, &image,
                                           lut.baseAddress!, lut.baseAddress!,
                                           lut.baseAddress!, identity.baseAddress!,
                                           vImage_Flags(kvImageNoFlags))
            }
        }
        return error == kvImageNoError ? pixelBuffer : nil
    }

    /// Tag a frame with colorimetry from settings if the backend didn't report it.
    /// Without tags the preview layer and the player interpret color differently.
    /// The values come from ColorTags — the same table the recorded file uses.
    /// NOTE: the buffer handed to the writer must keep standard tags — the
    /// encoder color-converts pixels when buffer tags mismatch the file tags
    /// (verified on device: a display-gamma tag here darkened recorded shadows).
    func tagColorIfUntagged(_ pixelBuffer: CVPixelBuffer) {
        guard CVBufferCopyAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey,
                                     nil) == nil else { return }
        ColorTags.tag(pixelBuffer, preset: config.settings.colorTagPreset)
    }
}
