import CaptureCore
import CDeckLink
import Foundation
import Testing
@testable import TakeShotKit

/// The boundary where the board's HDR report becomes a domain value.
///
/// Everything here is synthetic — there is no board and no HDR camera on this
/// machine — so what is pinned is the MAPPING, which is where the judgement
/// calls live. What only an UltraStudio plus an HDR source can confirm is
/// whether the board fills these fields at all, and with what.
struct HDRBackendTests {
    private func reported(eotf: Int, colorspace: Int = 3,
                          maxCLL: Double = 0) -> CDLFrameColorimetry {
        let value = CDLFrameColorimetry()
        value.hasHDRMetadata = true
        value.eotf = Int32(eotf)
        value.colorspace = Int32(colorspace)
        value.maxContentLightLevel = maxCLL
        return value
    }

    /// CTA-861.3's EOTF field, as the app reads it.
    @Test func theEOTFFieldPicksTheTransfer() {
        #expect(DeckLinkBackendAdapter.colorimetry(reported(eotf: 2)).transfer
            == .pq)
        #expect(DeckLinkBackendAdapter.colorimetry(reported(eotf: 3)).transfer
            == .hlg)
        // 0 is plain SDR gamma
        #expect(DeckLinkBackendAdapter.colorimetry(reported(eotf: 0)) == .sdr)
        // …and 1 — "HDR, traditional gamma" — is treated as SDR, because it
        // names no transfer function anyone can invert. It is a hint that the
        // content is bright, not a curve, and tone mapping on it would be a
        // guess.
        #expect(DeckLinkBackendAdapter.colorimetry(reported(eotf: 1)) == .sdr)
        // an EOTF nobody has heard of is SDR too, the safe direction
        #expect(DeckLinkBackendAdapter.colorimetry(reported(eotf: 7)) == .sdr)
    }

    /// A frame the board did not flag says nothing at all, whatever else is in
    /// the structure.
    @Test func aFrameWithoutTheFlagIsSDR() {
        let value = reported(eotf: 2)
        value.hasHDRMetadata = false
        #expect(DeckLinkBackendAdapter.colorimetry(value) == .sdr)
        #expect(DeckLinkBackendAdapter.colorimetry(nil) == .sdr)
    }

    /// A PQ or HLG signal whose colorspace the board did not fill in is taken
    /// as Rec.2020, because BT.2100 defines both transfers only on Rec.2020
    /// primaries. Assuming Rec.709 there would silently desaturate every HDR
    /// source whose camera happens to leave the field empty.
    @Test func anUnreportedColorspaceMeansRec2020UnderPQ() {
        #expect(DeckLinkBackendAdapter
            .colorimetry(reported(eotf: 2, colorspace: 0)).primaries == .rec2020)
        #expect(DeckLinkBackendAdapter
            .colorimetry(reported(eotf: 2, colorspace: 3)).primaries == .rec2020)
        // …but a board that explicitly says Rec.709 is believed
        #expect(DeckLinkBackendAdapter
            .colorimetry(reported(eotf: 2, colorspace: 2)).primaries == .rec709)
    }

    /// Static metadata rides along when there is any, and is absent when the
    /// board filled none of it in — a `clli` full of zeros claims a black
    /// picture rather than saying nothing.
    @Test func theStaticMetadataIsCarriedOnlyWhenThereIsAny() {
        #expect(DeckLinkBackendAdapter.colorimetry(reported(eotf: 2))
            .displayMetadata == nil)
        let withCLL = DeckLinkBackendAdapter
            .colorimetry(reported(eotf: 2, maxCLL: 1000)).displayMetadata
        #expect(withCLL?.maxContentLightLevel == 1000)
        // primaries only count when all four are present: three of four is a
        // board mid-update, not a mastering display
        let partial = reported(eotf: 2, maxCLL: 1000)
        partial.redX = 0.708
        partial.greenX = 0.170
        #expect(DeckLinkBackendAdapter.colorimetry(partial)
            .displayMetadata?.displayPrimaries == nil)
        partial.blueX = 0.131
        partial.whiteX = 0.3127
        #expect(DeckLinkBackendAdapter.colorimetry(partial)
            .displayMetadata?.displayPrimaries != nil)
    }

    /// The badge the operator reads, and what it says for a plain signal.
    @Test func theBadgeNamesWhatTheCrewCallsIt() {
        #expect(WireColorimetry.sdr.badge == nil)
        #expect(WireColorimetry(transfer: .pq, primaries: .rec2020).badge
            == "PQ / 2020")
        #expect(WireColorimetry(transfer: .hlg, primaries: .rec2020).badge
            == "HLG / 2020")
        #expect(WireColorimetry(transfer: .pq, primaries: .rec709).badge == "PQ")
    }
}
