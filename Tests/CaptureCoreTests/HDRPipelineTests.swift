@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import CaptureCore

/// An HDR signal through the pipeline rather than through a table on its own:
/// what the display buffer is tagged with, what the scopes are handed, what the
/// operator's setting can override, and what the take is latched with.
struct HDRPipelineTests {
    private static let pq = WireColorimetry(transfer: .pq, primaries: .rec2020)

    private func pipeline(in root: URL,
                          hdrMode: String? = nil) -> CapturePipeline {
        var settings = CaptureSettings()
        settings.capture.destinationPath = root.path
        settings.capture.detectionMode = .manual
        settings.capture.preRollFrames = 0
        settings.capture.hdrMode = hdrMode
        return CapturePipeline(config: .init(settings: settings, takeNumber: 1))
    }

    private func format() -> CaptureFormat {
        CaptureFormat(width: 96, height: 64, frameRate: 25, timecodeFPS: 25,
                      name: "96x64", isRGB444: false, bitDepth: 10)
    }

    private func greyWire() throws -> CVPixelBuffer {
        try V210Fixtures.makeGrey(width: 96, height: 64) { _, _ in
            V210Fixtures.midGrey
        }
    }

    /// The signal's own reading reaches the converters and the scopes, and the
    /// display buffer is tagged with what it actually holds: the camera's
    /// Rec.2020 primaries and — because the tone map has already happened — a
    /// Rec.709 transfer. Tagging it PQ would ask ColorSync to apply the PQ curve
    /// to something that is no longer PQ.
    @Test func anHDRSignalTagsTheDisplayBufferForWhatItHolds() throws {
        let root = TestMedia.scratchDirectory("HDRPipelineTag")
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = pipeline(in: root)
        pipeline.adoptColorimetry(Self.pq)
        let leveled = try #require(
            pipeline.levelledFrame(from: try greyWire(), format: format()))
        let primaries = CVBufferCopyAttachment(
            leveled.display, kCVImageBufferColorPrimariesKey, nil) as? NSString
        let transfer = CVBufferCopyAttachment(
            leveled.display, kCVImageBufferTransferFunctionKey, nil) as? NSString
        #expect(primaries == (kCVImageBufferColorPrimaries_ITU_R_2020 as NSString))
        #expect(transfer
            == (kCVImageBufferTransferFunction_ITU_R_709_2 as NSString))
        // the scopes get the wire AND what its codes mean
        let scopeSource = try #require(leveled.scopeSource)
        #expect(scopeSource.colorimetry == Self.pq)
        #expect(scopeSource.levels == .limited, "HDR moved the levels answer")
    }

    /// An SDR signal is tagged exactly as it always was.
    @Test func anSDRSignalIsTaggedExactlyAsBefore() throws {
        let root = TestMedia.scratchDirectory("HDRPipelineSDRTag")
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = pipeline(in: root)
        let leveled = try #require(
            pipeline.levelledFrame(from: try greyWire(), format: format()))
        let primaries = CVBufferCopyAttachment(
            leveled.display, kCVImageBufferColorPrimariesKey, nil) as? NSString
        #expect(primaries
            == (kCVImageBufferColorPrimaries_ITU_R_709_2 as NSString))
        #expect(try #require(leveled.scopeSource).colorimetry == .sdr)
    }

    /// "Treat as SDR" is absolute: the board can report whatever it likes and
    /// nothing downstream sees it. This is the operator's answer to a converter
    /// in the chain passing HDR metadata through an already-converted signal.
    @Test func theOffSettingPinsEverythingToSDR() throws {
        let root = TestMedia.scratchDirectory("HDRPipelineOff")
        defer { try? FileManager.default.removeItem(at: root) }
        let forced = pipeline(in: root, hdrMode: HDRMode.off.rawValue)
        forced.hdrMode = .off
        forced.adoptColorimetry(Self.pq)
        #expect(forced.signalColorimetry == .sdr)
        let leveled = try #require(
            forced.levelledFrame(from: try greyWire(), format: format()))
        let primaries = CVBufferCopyAttachment(
            leveled.display, kCVImageBufferColorPrimariesKey, nil) as? NSString
        #expect(primaries
            == (kCVImageBufferColorPrimaries_ITU_R_709_2 as NSString))
        // …and it shows the same picture a build without HDR would
        let sdrPipeline = pipeline(in: root)
        let sdr = try #require(
            sdrPipeline.levelledFrame(from: try greyWire(), format: format()))
        #expect(Self.greenByte(leveled.display) == Self.greenByte(sdr.display))
    }

    /// The record decision is untouched: a PQ YCbCr take still carries no
    /// levels key, because a video-range YCbCr file states its own range and
    /// tagging it would expand it twice. HDR changes the transfer tag, not the
    /// levels one.
    @Test func hdrDoesNotChangeTheLevelsKeyDecision() throws {
        let root = TestMedia.scratchDirectory("HDRPipelineLevelsKey")
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = pipeline(in: root)
        pipeline.adoptColorimetry(Self.pq)
        _ = pipeline.levelledFrame(from: try greyWire(), format: format())
        #expect(!pipeline.recordCarriesWireCodes,
                "a v210 HDR take was tagged as carrying wire codes")
        #expect(pipeline.recordBytesPerPixel == 3)
    }

    /// The file's colorimetry preset comes from the signal and overrides the
    /// operator's, because a file that does not state PQ is read a hundred
    /// times wrong.
    @Test func theFilePresetFollowsTheSignal() {
        #expect(WireColorimetry.sdr.filePreset == nil)
        #expect(Self.pq.filePreset == ColorTags.pqPreset)
        #expect(WireColorimetry(transfer: .hlg, primaries: .rec2020)
            .filePreset == ColorTags.hlgPreset)
        // …and the display preset is a different answer on purpose
        #expect(Self.pq.displayPreset == ColorTags.rec2020Preset)
        #expect(WireColorimetry.sdr.displayPreset == nil)
        // a (hypothetical) HDR signal on Rec.709 primaries needs no gamut tag
        #expect(WireColorimetry(transfer: .pq, primaries: .rec709)
            .displayPreset == nil)
    }

    /// The presets resolve to the constants a decoder acts on.
    @Test func thePresetsCarryTheStandardConstants() {
        let pq = ColorTags.values(for: ColorTags.pqPreset)
        #expect(pq.avTransfer == AVVideoTransferFunction_SMPTE_ST_2084_PQ)
        #expect(pq.avPrimaries == AVVideoColorPrimaries_ITU_R_2020)
        #expect(pq.avMatrix == AVVideoYCbCrMatrix_ITU_R_2020)
        let hlg = ColorTags.values(for: ColorTags.hlgPreset)
        #expect(hlg.avTransfer == AVVideoTransferFunction_ITU_R_2100_HLG)
        // the SDR presets are untouched
        #expect(ColorTags.values(for: nil).avTransfer
            == AVVideoTransferFunction_ITU_R_709_2)
        #expect(ColorTags.values(for: ColorTags.rec2020Preset).avTransfer
            == AVVideoTransferFunction_ITU_R_709_2)
    }

    /// A stored setting nobody recognises means `auto`, so a settings file from
    /// a build that never had this field behaves the way the feature is meant
    /// to be used.
    @Test func theSettingResolvesConservatively() {
        #expect(HDRMode.resolved(nil) == .auto)
        #expect(HDRMode.resolved("") == .auto)
        #expect(HDRMode.resolved("nonsense") == .auto)
        #expect(HDRMode.resolved("off") == .off)
        #expect(HDRMode.auto.applied(to: Self.pq) == Self.pq)
        #expect(HDRMode.off.applied(to: Self.pq) == .sdr)
    }

    private static func greenByte(_ buffer: CVPixelBuffer) -> Int {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return -1 }
        return Int(base.assumingMemoryBound(to: UInt8.self)[1])
    }
}
