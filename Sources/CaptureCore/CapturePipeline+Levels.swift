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
    /// The frame the scopes measure, and what its code values mean.
    ///
    /// Not always the display buffer: see `LevelledFrame.scopeSource`.
    struct ScopeSourceFrame {
        let buffer: CVPixelBuffer
        let levels: ScopeWireLevels
    }

    /// One frame after the levels stage: the 8-bit BGRA buffer everything
    /// downstream reads, plus the record buffer carrying the wire codes when
    /// the wire carried a high-bit-depth RGB format — 'r210' or 'R12B' (nil for
    /// every other format).
    struct LevelledFrame {
        let display: CVPixelBuffer
        let wireRecord: CVPixelBuffer?
        /// The frame the scopes should read INSTEAD of the display buffer, when
        /// the wire carries a signal the display buffer cannot represent.
        ///
        /// A 10- or 12-bit RGB wire is exactly that case, twice over: the
        /// display buffer is 8-bit, so a scope reading it is quantized to 256
        /// levels however good the source was, and the limited→full expansion
        /// clamps everything outside the nominal pair — the sub-blacks and
        /// super-whites a camera legally sends, which is what the operator
        /// opens a scope to look for. The retained wire buffer is the ONLY work
        /// this adds to the capture queue: the analysis itself already runs on
        /// its own queue.
        ///
        /// nil for every other format, where the display buffer already is the
        /// best reading available — and where the scopes keep showing the
        /// preview LUT, as they always have.
        let scopeSource: ScopeSourceFrame?
    }

    /// The converter for a wire format, or nil when the frame is one the 8-bit
    /// path handles. The two high-bit-depth RGB formats differ in their pixel
    /// packing and their record format, not in what the levels stage does with
    /// them, so this is the only place the pipeline names them.
    func wireConverter(for pixelFormat: OSType) -> WireConverter? {
        switch pixelFormat {
        case TenBitConverter.r210: return tenBitConverter
        case TwelveBitConverter.r12b: return twelveBitConverter
        default: return nil
        }
    }

    /// Levels and, for a high-bit-depth RGB wire, the split into display +
    /// record buffers. nil means the converter could not produce a frame and
    /// this one is dropped — the same `guard` the inline code had.
    func levelledFrame(from pixelBuffer: CVPixelBuffer,
                       format: CaptureFormat) -> LevelledFrame? {
        let inputLevels = effectiveInputLevels(for: format)
        // 10- or 12-bit RGB wire ('r210'/'R12B'): one pass yields the
        // full-range display BGRA AND the record buffer carrying the wire
        // codes; levels are applied inside the converter, so the 8-bit stage
        // below must not run again
        if let converter =
            wireConverter(for: CVPixelBufferGetPixelFormatType(pixelBuffer)) {
            let mode = InputLevels.resolved(inputLevels)
            converter.setLevels(mode)
            guard let split = converter.convert(pixelBuffer) else { return nil }
            tagColorIfUntagged(split.display)
            // What the NEXT take will carry, so the file can say so (see
            // `TakeWriter.levelsKey`). Only this branch records wire codes: the
            // 8-bit path's record buffer IS the expanded display buffer, and on
            // `full` the wire codes already are display values.
            recordCarriesWireCodes = mode == .limited
            recordBytesPerPixel = converter.recordBytesPerPixel
            // The graticule marks where NOMINAL black and white are, whatever
            // the expansion then does with the codes outside them — that is
            // what makes the excursion visible as an excursion.
            return LevelledFrame(
                display: split.display, wireRecord: split.record,
                scopeSource: ScopeSourceFrame(
                    buffer: pixelBuffer,
                    levels: mode == .full ? .full : .limited))
        }
        recordCarriesWireCodes = false
        recordBytesPerPixel = 4
        // nil is auto on a signal that is not RGB 4:4:4 — nothing is expanded,
        // and the mode enum has no case for "the question was never asked".
        guard let inputLevels else {
            return LevelledFrame(display: pixelBuffer, wireRecord: nil,
                                 scopeSource: nil)
        }
        let mode = InputLevels.resolved(inputLevels)
        let leveled = mode.expandsEightBit
            ? (expandLimitedRGB(pixelBuffer) ?? pixelBuffer)
            : pixelBuffer
        return LevelledFrame(display: leveled, wireRecord: nil,
                             scopeSource: nil)
    }

    /// The levels decision for this frame, logged whenever it changes.
    ///
    /// input levels: the setting states what the SOURCE carries on the wire.
    /// "limited" (studio swing) is expanded once to the full-range BGRA the
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

    /// Expand a studio-swing RGB frame for the screen, in place (vImage byte
    /// lookup — no CoreImage pass, no extra buffer). BGRA only, and the buffer
    /// is one the capture path owns, which is what makes in place safe here.
    ///
    /// The window is the nominal pair 16–235: on this path the display buffer
    /// is also what the writer gets, so the excursions cannot be kept — an
    /// 8-bit wire has fifteen codes of footroom, and a black that sits 6 % up
    /// the scale on the monitor costs the operator an exposure judgement every
    /// time. The 10-bit path above keeps them, in the file, where they matter.
    private func expandLimitedRGB(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        StudioSwing.expand(pixelBuffer, into: pixelBuffer) ? pixelBuffer : nil
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
