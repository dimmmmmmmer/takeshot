import CoreVideo
import Foundation
import Metal
import QuartzCore
import Testing

@testable import CaptureCore

/// What HDR does to the exposure aids, and the measurement behind the answer:
/// almost nothing, because the display transform was built so that it would.
///
/// The transform is an exact ratio to diffuse white everywhere below its knee,
/// so every band from crushed black through skin covers the same fraction of
/// white it covers in SDR. False colour, EL Zone and the zebra therefore keep
/// working with no retuning at all. What changes is what the NUMBERS on them
/// mean, and the app has to say so — an operator told "95 %" under PQ is being
/// told a percentage of a scale PQ does not have.
struct HDRAssistTests {
    /// The exposure bands below the knee cover the same fraction of diffuse
    /// white under PQ that they cover of white in SDR. This is the measurement
    /// the "the tools need no retuning" decision rests on.
    @Test func theExposureBandsMeanTheSameFractionOfWhite() {
        // the false-colour band boundaries, as fractions of the display scale
        for boundary in [0.025, 0.08, 0.36, 0.44, 0.52, 0.58] {
            // SDR: the display value IS the fraction of white, through 1886
            let sdrRatio = pow(boundary, 2.4)
            // HDR: invert the transform to the luminance, against diffuse white
            let nits = HDRTransfer.nits(forDisplaySignal: boundary)
            let hdrRatio = nits / HDRTransfer.referenceWhiteNits
            #expect(abs(sdrRatio - hdrRatio) < 1e-9,
                    "band at \(boundary): SDR \(sdrRatio) vs HDR \(hdrRatio)")
        }
    }

    /// …and the two bands ABOVE the knee are the ones that stop meaning what
    /// they say, so the legend relabels exactly those two and leaves the rest.
    @Test func onlyTheTopTwoLegendLabelsChange() {
        let sdr = AssistLegend.falseColorLabels(for: .sdr)
        let hdr = AssistLegend.falseColorLabels(for: .pq)
        #expect(sdr == AssistLegend.falseColorLabels)
        #expect(sdr.count == hdr.count)
        #expect(Array(sdr.prefix(7)) == Array(hdr.prefix(7)),
                "an exposure band was relabelled: \(hdr)")
        #expect(sdr[7] == "92-97" && sdr[8] == "clip")
        #expect(hdr[7] != sdr[7] && hdr[8] != sdr[8], "HDR labels: \(hdr)")
        // and they name luminances the specular range actually covers
        #expect(hdr[7].contains("-"), "the near-clip band lost its range: \(hdr[7])")
        #expect(hdr[8].hasSuffix("+"), "the clip band lost its open end: \(hdr[8])")
        let clipNits = Int(hdr[8].dropLast()) ?? 0
        #expect(clipNits > Int(HDRTransfer.referenceWhiteNits),
                "the clip band starts below diffuse white: \(clipNits)")
    }

    /// The legend's swatches are unchanged — same palette, same count, same
    /// order. Only the two labels moved.
    @Test func theLegendPaintsTheSameColoursUnderHDR() {
        let sdr = AssistLegend.entries(for: .falseColor, transfer: .sdr)
        let hdr = AssistLegend.entries(for: .falseColor, transfer: .pq)
        #expect(sdr.count == hdr.count)
        #expect(sdr.map(\.color) == hdr.map(\.color))
        // EL Zone is a STOP scale, and a stop is a ratio the transform
        // preserves, so nothing about it changes at all
        #expect(AssistLegend.entries(for: .elZone, transfer: .sdr)
            == AssistLegend.entries(for: .elZone, transfer: .pq))
    }

    /// A zebra set at a display level fires at a stated luminance, and the
    /// stated luminance is the exact inverse of what the picture went through.
    /// This is what makes "put the zebra on diffuse white" a thing an operator
    /// can actually do.
    @Test func theZebraThresholdReadsBackInNits() throws {
        let atWhite = HDRTransfer.displaySignal(
            forNits: HDRTransfer.referenceWhiteNits)
        let back = try #require(
            SignalTransfer.pq.nits(forDisplaySignal: atWhite))
        #expect(abs(back - HDRTransfer.referenceWhiteNits) < 1,
                "diffuse white came back as \(back)")
        // the panel's default 95 % under PQ is just above diffuse white, which
        // is a useful place for it and NOT what "95 %" says in SDR
        let ninetyFive = try #require(
            SignalTransfer.pq.nits(forDisplaySignal: 0.95))
        #expect(ninetyFive > HDRTransfer.referenceWhiteNits)
        #expect(ninetyFive < 400)
        // …and on an SDR signal the question has no answer, so the panel keeps
        // printing a percentage
        #expect(SignalTransfer.sdr.nits(forDisplaySignal: 0.95) == nil)
    }
}

/// The preview layer's colorspace follows the frame it is handed.
///
/// A Rec.2020 frame shown through a Rec.709 layer is a real error rather than a
/// cosmetic one: ColorSync would map the wrong gamut to the display and every
/// saturated colour would land short. This is the one place HDR touches the
/// per-surface render, and it costs an attachment lookup and a CFEqual per
/// presented frame — the body runs only when the primaries actually change,
/// which for an SDR session is never.
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil,
                "no Metal device on this machine"))
struct HDRPreviewLayerTests {
    private func buffer(primaries: CFString?) throws -> CVPixelBuffer {
        var made: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 32, 16,
                            kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]]
                                as CFDictionary, &made)
        let out = try #require(made)
        if let primaries {
            CVBufferSetAttachment(out, kCVImageBufferColorPrimariesKey,
                                  primaries, .shouldPropagate)
        }
        return out
    }

    @Test func theLayerAdoptsTheFramesPrimaries() throws {
        let layer = MetalPreviewLayer()
        let before = layer.colorspace
        // an SDR frame changes nothing at all
        layer.adoptColorSpace(of: try buffer(
            primaries: kCVImageBufferColorPrimaries_ITU_R_709_2))
        #expect(layer.colorspace === before)
        // a Rec.2020 frame installs the Rec.2020 space
        layer.adoptColorSpace(of: try buffer(
            primaries: kCVImageBufferColorPrimaries_ITU_R_2020))
        let wide = try #require(layer.colorspace)
        #expect(!(wide === before), "the layer kept its Rec.709 space")
        #expect(layer.installedPrimaries
            == kCVImageBufferColorPrimaries_ITU_R_2020)
        // a second frame with the same primaries does not reallocate
        layer.adoptColorSpace(of: try buffer(
            primaries: kCVImageBufferColorPrimaries_ITU_R_2020))
        #expect(layer.colorspace === wide)
        // an UNTAGGED frame makes no claim and must not flip the layer back:
        // a source that tags some frames and not others would otherwise
        // oscillate between two gamuts
        layer.adoptColorSpace(of: try buffer(primaries: nil))
        #expect(layer.colorspace === wide)
        // …and going back to Rec.709 works
        layer.adoptColorSpace(of: try buffer(
            primaries: kCVImageBufferColorPrimaries_ITU_R_709_2))
        #expect(layer.installedPrimaries
            == kCVImageBufferColorPrimaries_ITU_R_709_2)
    }
}
