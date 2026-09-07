import AVFoundation
import CoreVideo
import Foundation
import Testing

@testable import CaptureCore

/// The colorimetry table both writers derive from. The file exists because the
/// writer's AVVideo* switch and the pipeline's kCVImageBuffer* switch had
/// drifted apart once already — so the test pins BOTH sides of every preset
/// and that the two sides always name the same standard.
@Suite struct ColorTagsTests {
    @Test func the709PresetIsTheDefaultAndTheFallback() {
        for preset in [nil, "709", "anything else", ""] {
            let values = ColorTags.values(for: preset)
            #expect(values.cvPrimaries
                == kCVImageBufferColorPrimaries_ITU_R_709_2,
                    "preset \(String(describing: preset))")
            #expect(values.avPrimaries == AVVideoColorPrimaries_ITU_R_709_2)
            #expect(values.avMatrix == AVVideoYCbCrMatrix_ITU_R_709_2)
        }
    }

    @Test func the601PresetIsSMPTECWithThe709Curve() {
        let values = ColorTags.values(for: "601")
        #expect(values.cvPrimaries == kCVImageBufferColorPrimaries_SMPTE_C)
        #expect(values.avPrimaries == AVVideoColorPrimaries_SMPTE_C)
        #expect(values.cvMatrix == kCVImageBufferYCbCrMatrix_ITU_R_601_4)
        #expect(values.avMatrix == AVVideoYCbCrMatrix_ITU_R_601_4)
        // 601 material is still gamma-encoded with the 709 curve
        #expect(values.avTransfer == AVVideoTransferFunction_ITU_R_709_2)
    }

    /// 2020 SDR: wide primaries and matrix, 709 transfer on BOTH sides —
    /// AVFoundation has no 2020-SDR transfer constant, and the file and the
    /// preview must be tagged identically or they render differently.
    @Test func the2020PresetKeepsThe709TransferOnBothSides() {
        let values = ColorTags.values(for: "2020")
        #expect(values.cvPrimaries == kCVImageBufferColorPrimaries_ITU_R_2020)
        #expect(values.avPrimaries == AVVideoColorPrimaries_ITU_R_2020)
        #expect(values.cvMatrix == kCVImageBufferYCbCrMatrix_ITU_R_2020)
        #expect(values.avMatrix == AVVideoYCbCrMatrix_ITU_R_2020)
        #expect(values.cvTransfer
            == kCVImageBufferTransferFunction_ITU_R_709_2)
        #expect(values.avTransfer == AVVideoTransferFunction_ITU_R_709_2)
    }

    /// The AVVideoColorProperties dictionary is the file-side table verbatim.
    @Test func videoColorPropertiesCarryTheSameThreeKeys() {
        for preset in ["709", "601", "2020"] {
            let values = ColorTags.values(for: preset)
            let properties = ColorTags.videoColorProperties(for: preset)
            #expect(properties[AVVideoColorPrimariesKey] == values.avPrimaries)
            #expect(properties[AVVideoTransferFunctionKey] == values.avTransfer)
            #expect(properties[AVVideoYCbCrMatrixKey] == values.avMatrix)
            #expect(properties.count == 3)
        }
    }

    /// **`preset(of:)` is the inverse of `tag`, on every preset there is.**
    ///
    /// It exists because a consumer downstream of the display stage has to
    /// DECLARE the colour it was handed. `SRTVideoEncoder` did not ask — it
    /// declared Rec.709 as a constant over a buffer this app had itself tagged
    /// Rec.2020 on every HDR day.
    @Test func aTaggedBufferCanBeAskedWhichPresetItIs() {
        for preset in [ColorTags.rec2020Preset, ColorTags.pqPreset,
                       ColorTags.hlgPreset, "601"] {
            let buffer = TestMedia.pixelBuffer()
            ColorTags.tag(buffer, preset: preset)
            #expect(ColorTags.preset(of: buffer) == preset,
                    """
                    \(preset) came back as \
                    \(ColorTags.preset(of: buffer) ?? "nil")
                    """)
        }
    }

    /// 709 and an untagged buffer are the SAME answer — the default — and both
    /// are nil, which is what every caller passes back into `values(for:)`.
    @Test func sevenOhNineAndAnUntaggedBufferAreBothTheDefault() {
        let untouched = TestMedia.pixelBuffer()
        #expect(ColorTags.preset(of: untouched) == nil)
        let tagged = TestMedia.pixelBuffer()
        ColorTags.tag(tagged, preset: "709")
        #expect(ColorTags.preset(of: tagged) == nil,
                "709 came back as something other than the default")
    }

    /// `tag` stamps the buffer with exactly the preset's three attachments.
    @Test func taggingABufferStampsThePresetsAttachments() {
        for preset in ["709", "601", "2020"] {
            let buffer = TestMedia.pixelBuffer()
            ColorTags.tag(buffer, preset: preset)
            let values = ColorTags.values(for: preset)
            for (key, expected) in [
                (kCVImageBufferColorPrimariesKey, values.cvPrimaries),
                (kCVImageBufferTransferFunctionKey, values.cvTransfer),
                (kCVImageBufferYCbCrMatrixKey, values.cvMatrix),
            ] {
                let attached = CVBufferCopyAttachment(buffer, key, nil)
                #expect(attached as? String == expected as String,
                        "\(preset): \(key) is \(String(describing: attached))")
            }
        }
    }
}
