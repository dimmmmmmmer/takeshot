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
    /// downstream reads, plus the record buffer carrying the wire codes when the
    /// wire carried a high-bit-depth format — 'r210', 'R12B' or 'v210' (nil for
    /// every other format).
    struct LevelledFrame {
        let display: CVPixelBuffer
        let wireRecord: CVPixelBuffer?
        /// The frame the scopes should read INSTEAD of the display buffer, when
        /// the wire carries a signal the display buffer cannot represent.
        ///
        /// Every high-bit-depth wire is exactly that case, twice over: the
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
    /// path handles. The three high-bit-depth formats differ in their pixel
    /// packing, their colour space and their record format, not in what the
    /// levels stage does with them, so this is the only place the pipeline names
    /// them.
    func wireConverter(for pixelFormat: OSType) -> WireConverter? {
        switch pixelFormat {
        case TenBitConverter.r210: return tenBitConverter
        case TwelveBitConverter.r12b: return twelveBitConverter
        case TenBitYUVConverter.v210: return tenBitYUVConverter
        default: return nil
        }
    }

    /// Levels and, for a high-bit-depth RGB wire, the split into display +
    /// record buffers. nil means the converter could not produce a frame and
    /// this one is dropped — the same `guard` the inline code had.
    func levelledFrame(from pixelBuffer: CVPixelBuffer,
                       format: CaptureFormat) -> LevelledFrame? {
        let inputLevels = autoResolvedLevels(for: format)
        // A high-bit-depth wire ('r210'/'R12B'/'v210'): one pass yields the
        // full-range display BGRA AND the record buffer carrying the wire
        // codes; levels are applied inside the converter, so the 8-bit stage
        // below must not run again
        if let converter =
            wireConverter(for: CVPixelBufferGetPixelFormatType(pixelBuffer)) {
            let mode = InputLevels.resolved(inputLevels)
            // the CONVERTER's reading, not the setting string: auto on a YCbCr
            // signal leaves the setting nil and still resolves to studio swing
            // here, which is what SDI and HDMI YCbCr always carry
            logLevels(effective: mode.rawValue, rgb444: format.isRGB444)
            converter.setLevels(mode)
            guard let split = converter.convert(pixelBuffer) else { return nil }
            tagColorIfUntagged(split.display)
            // What the NEXT take will carry, so the file can say so (see
            // `TakeWriter.levelsKey`). Only this branch can record wire codes:
            // the 8-bit path's record buffer IS the expanded display buffer, and
            // on `full` the wire codes already are display values.
            //
            // The converter has the last word, and that is not a formality: a
            // 'v210' take is a video-range YCbCr file whose own tags already say
            // what its codes mean, so tagging it as wire would expand it a
            // second time on the way back out.
            recordCarriesWireCodes =
                mode == .limited && converter.recordNeedsPlaybackExpansion
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
        // nil is auto on a signal that is not RGB 4:4:4 — nothing is expanded
        // HERE, and the mode enum has no case for "the question was never
        // asked". An 8-bit '2vuy' frame goes through this branch and is handed
        // on untouched: it is the preview layer's YCbCr matrix that expands it,
        // which is why 10-bit YUV capture is the depth at which the app starts
        // owning that conversion (see `TenBitYUVConverter`).
        guard let inputLevels else {
            logLevels(effective: "passthrough", rgb444: format.isRGB444)
            return LevelledFrame(display: pixelBuffer, wireRecord: nil,
                                 scopeSource: nil)
        }
        logLevels(effective: inputLevels, rgb444: format.isRGB444)
        let mode = InputLevels.resolved(inputLevels)
        let leveled = mode.expandsEightBit
            ? (expandLimitedRGB(pixelBuffer) ?? pixelBuffer)
            : pixelBuffer
        return LevelledFrame(display: leveled, wireRecord: nil,
                             scopeSource: nil)
    }

    /// The levels decision for this frame, as a setting string.
    ///
    /// input levels: the setting states what the SOURCE carries on the wire.
    /// "limited" (studio swing) is expanded once to the full-range BGRA the
    /// rest of the pipeline assumes; "full" passes through untouched (e.g.
    /// a playout device already set to Full output levels). auto (nil)
    /// assumes limited for RGB 4:4:4 HDMI (CTA-861 default). Conversion to
    /// legal-range YUV in the recorded file is the encoder's job — never
    /// done on pixels here, so it can't be applied twice.
    ///
    /// nil for a YCbCr signal on auto, and that nil still resolves to `limited`
    /// wherever a mode is actually needed (`InputLevels.resolved`) — which is
    /// right, because YCbCr is studio swing by SMPTE over SDI and by CTA-861
    /// over HDMI. The 8-bit path has nothing to do about it; the 10-bit YCbCr
    /// converter does the expansion itself.
    private func autoResolvedLevels(for format: CaptureFormat) -> String? {
        levelsMode ?? (format.isRGB444 ? "limited" : nil)
    }

    /// One log line per decision change — settles "is expansion active" without
    /// guessing (a stale-settings app instance once recorded an unexpanded take).
    ///
    /// `effective` is what this frame's path is really about to do rather than
    /// what the setting says: a high-bit-depth wire resolves auto INSIDE its
    /// converter, so a line reading "passthrough" while a 'v210' frame was being
    /// expanded on the nominal pair would be the log lying about the one thing
    /// it exists for.
    private func logLevels(effective: String, rgb444: Bool) {
        guard lastLoggedLevels != effective else { return }
        lastLoggedLevels = effective
        os_log("levels: mode=%{public}s rgb444=%{public}d effective=%{public}s",
               log: Self.levelsLog, type: .default,
               levelsMode ?? "auto", rgb444 ? 1 : 0, effective)
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
