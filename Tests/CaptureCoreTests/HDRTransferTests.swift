import Foundation
import Testing

@testable import CaptureCore

/// The HDR transfer curves and the display transform built on them, pinned
/// against the standards they come from rather than against themselves.
///
/// Every number below is either published (SMPTE ST 2084, ARIB STD-B67,
/// ITU-R BT.2100, ITU-R BT.2408) or derived from one that is. Nothing here
/// needs hardware — a transfer function is arithmetic — which is exactly why
/// this is the layer the rest of the HDR work is built on.
struct HDRTransferTests {
    // MARK: - SMPTE ST 2084 (PQ)

    /// The PQ signal levels the industry quotes, to the precision they are
    /// quoted at (half a percent of the scale): 26 cd/m² at 38 %, 100 at 51 %,
    /// 203 at 58 %, 1000 at 75 % and 4000 at 90 %.
    ///
    /// A loose tolerance on purpose — these are the rounded figures a colourist
    /// says out loud, and pinning them to four decimals would be pinning this
    /// implementation to itself. Exactness is the round-trip test below.
    @Test func pqLandsOnThePublishedSignalLevels() {
        let expected: [(nits: Double, signal: Double)] = [
            (26, 0.38), (100, 0.51), (203, 0.58), (1000, 0.75),
            (4000, 0.90), (10_000, 1.0),
        ]
        for pair in expected {
            let signal = HDRTransfer.pqSignal(pair.nits)
            #expect(abs(signal - pair.signal) < 0.005,
                    "\(pair.nits) cd/m² -> \(signal), expected ~\(pair.signal)")
        }
    }

    /// EOTF and its inverse are inverses, everywhere on the scale.
    @Test func pqRoundTripsThroughItsOwnInverse() {
        for step in 0...100 {
            let signal = Double(step) / 100
            let back = HDRTransfer.pqSignal(HDRTransfer.pqNits(signal))
            #expect(abs(back - signal) < 0.0005,
                    "signal \(signal) came back as \(back)")
        }
    }

    /// The ends: signal 0 is black and signal 1 is the top of the PQ scale.
    @Test func pqEndsAreBlackAndTenThousand() {
        #expect(HDRTransfer.pqNits(0) < 0.0001)
        #expect(abs(HDRTransfer.pqNits(1) - 10_000) < 1)
        // and out-of-range codes clamp rather than extrapolating, which is the
        // same rule the SDR display table follows for the wire's excursions
        #expect(HDRTransfer.pqNits(-0.2) == HDRTransfer.pqNits(0))
        #expect(HDRTransfer.pqNits(1.5) == HDRTransfer.pqNits(1))
    }

    // MARK: - ARIB STD-B67 / BT.2100 (HLG)

    /// The OETF and its inverse meet at the 1/12 knee and are inverses either
    /// side of it.
    @Test func hlgRoundTripsThroughItsOwnInverse() {
        for step in 0...100 {
            let signal = Double(step) / 100
            let back = HDRTransfer.hlgSignal(HDRTransfer.hlgScene(signal))
            #expect(abs(back - signal) < 0.0005,
                    "signal \(signal) came back as \(back)")
        }
        // the published knee: signal 0.5 is scene 1/12
        #expect(abs(HDRTransfer.hlgScene(0.5) - 1.0 / 12) < 1e-9)
    }

    /// HLG's reference white is signal 0.75, which is 26.5 % of peak in scene
    /// linear — the number BT.2100's OOTF turns into 203 cd/m².
    @Test func hlgReferenceWhiteIsTwentySixPercentOfPeakLinear() {
        let scene = HDRTransfer.hlgScene(HDRTransfer.hlgReferenceWhiteSignal)
        #expect(abs(scene - 0.26496) < 0.0001, "scene linear \(scene)")
    }

    /// The measurement the whole design rests on: applying BT.2100's OOTF makes
    /// HLG and PQ two spellings of the SAME luminance. HLG's two reference
    /// signal levels come out at BT.2408's two reference luminances, to three
    /// figures — which is what lets one display transform serve both.
    @Test func hlgAndPQAgreeAtBothReferenceLevels() {
        let white = HDRTransfer.hlgNits(HDRTransfer.hlgReferenceWhiteSignal)
        #expect(abs(white - HDRTransfer.referenceWhiteNits) < 0.5,
                "HLG 75% is \(white) cd/m², BT.2408 says 203")
        let grey = HDRTransfer.hlgNits(0.38)
        #expect(abs(grey - HDRTransfer.referenceGreyNits) < 0.5,
                "HLG 38% is \(grey) cd/m², BT.2408 says 26")
        // and the two transfers put the same picture on the same display code
        let pqWhite = SignalTransfer.pq.displaySignal(
            forSignal: HDRTransfer.pqSignal(HDRTransfer.referenceWhiteNits))
        let hlgWhite = SignalTransfer.hlg.displaySignal(
            forSignal: HDRTransfer.hlgReferenceWhiteSignal)
        #expect(abs(pqWhite - hlgWhite) < 0.002,
                "PQ \(pqWhite) vs HLG \(hlgWhite)")
    }

    /// HLG signal 1.0 is the BT.2100 reference display's peak and nothing
    /// above it, so an HLG scale stops at 1000 cd/m² while a PQ one runs to
    /// 10 000. A readout that printed 4000 on an HLG waveform would be putting
    /// a number where the trace can never reach.
    @Test func hlgPeaksAtItsReferenceDisplay() {
        #expect(abs(HDRTransfer.hlgNits(1) - 1000) < 0.5)
        #expect(SignalTransfer.hlg.peakNits == 1000)
        #expect(SignalTransfer.pq.peakNits == 10_000)
        #expect(SignalTransfer.sdr.peakNits == nil)
    }

    // MARK: - the display transform

    /// The property that makes an HDR picture judgeable on an SDR monitor: an
    /// 18 % grey card reads in the same place whether the camera is in Rec.709
    /// or in PQ.
    ///
    /// BT.2408 grades that card to 26 cd/m². Through this transform it lands at
    /// 42.5 % of the display scale; a Rec.709 camera's own OETF puts 18 % scene
    /// reflectance at 40.9 %. Under two points of the scale apart — which is
    /// what an operator's exposure judgement transferring means in a number.
    @Test func aGreyCardReadsTheSameUnderPQAsUnderRec709() {
        let hdr = HDRTransfer.displaySignal(forNits: HDRTransfer.referenceGreyNits)
        // Rec.709 OETF of 18% scene linear
        let sdr = 1.099 * pow(0.18, 0.45) - 0.099
        #expect(abs(hdr - sdr) < 0.02,
                "HDR grey at \(hdr), SDR grey at \(sdr)")
        #expect(abs(hdr - 0.4247) < 0.001, "HDR grey at \(hdr)")
    }

    /// Diffuse white lands near the top of the scale but not on it, and that is
    /// the shoulder doing its job: the last few codes are left for the specular
    /// range so a highlight has shape instead of being a flat white patch.
    @Test func diffuseWhiteSitsJustBelowTheTopOfTheScale() {
        let white = HDRTransfer.displaySignal(
            forNits: HDRTransfer.referenceWhiteNits)
        #expect(abs(white - 0.946) < 0.002, "diffuse white at \(white)")
        let specular = HDRTransfer.displaySignal(forNits: 1000)
        #expect(specular > white, "1000 cd/m² did not clear diffuse white")
        #expect(specular < 1, "1000 cd/m² clipped flat")
        let peak = HDRTransfer.displaySignal(forNits: 10_000)
        #expect(peak > specular, "10 000 cd/m² did not clear 1000")
        #expect(peak <= 1)
    }

    /// Below the knee there is NO compression at all — the transform is a pure
    /// transfer conversion, so every ratio an operator judges exposure by is
    /// preserved exactly. Two luminances a stop apart stay a stop apart.
    @Test func nothingBelowTheKneeIsCompressed() {
        // a stop is a factor of two in luminance; below the knee the display
        // value is the luminance ratio raised to 1/2.4, so the RATIO of the
        // two display values is fixed and independent of where they sit
        let expected = pow(0.5, 1 / 2.4)
        for base in [4.0, 8.0, 16.0, 26.0, 50.0, 100.0] {
            let bright = HDRTransfer.displaySignal(forNits: base)
            let dark = HDRTransfer.displaySignal(forNits: base / 2)
            #expect(abs(dark / bright - expected) < 0.001,
                    "\(base) cd/m² and one stop down: \(dark / bright)")
        }
    }

    /// The transform is invertible, which is what the exposure aids read
    /// through: a zebra set at a display level has to be able to say what
    /// luminance it fires at.
    @Test func theTransformInvertsForTheAssistReadouts() {
        for nits in [1.0, 26.0, 100.0, 203.0, 400.0, 1000.0, 4000.0] {
            let display = HDRTransfer.displaySignal(forNits: nits)
            let back = HDRTransfer.nits(forDisplaySignal: display)
            #expect(abs(back - nits) / nits < 0.01,
                    "\(nits) cd/m² came back as \(back)")
        }
    }

    /// It is monotonic end to end. A tone map that is not is a picture with a
    /// contour in it, and a scope reading that cannot be trusted.
    @Test func theTransformIsMonotonic() {
        for transfer in [SignalTransfer.pq, .hlg] {
            var previous = -1.0
            for step in 0...1023 {
                let value = transfer.displaySignal(
                    forSignal: Double(step) / 1023)
                #expect(value >= previous,
                        "\(transfer.rawValue) went backwards at \(step)")
                previous = value
            }
        }
    }

    /// SDR is the identity, stated as a property of the one function every
    /// caller goes through rather than as a claim about a diff.
    @Test func sdrIsTheIdentity() {
        for step in 0...1023 {
            let signal = Double(step) / 1023
            #expect(SignalTransfer.sdr.displaySignal(forSignal: signal)
                == signal)
        }
        #expect(SignalTransfer.sdr.nits(forSignal: 0.5) == nil)
        #expect(SignalTransfer.sdr.signal(forNits: 203) == nil)
        #expect(SignalTransfer.sdr.nits(forDisplaySignal: 0.95) == nil)
        #expect(!SignalTransfer.sdr.isHDR)
        #expect(SignalTransfer.pq.isHDR && SignalTransfer.hlg.isHDR)
    }

    /// An unrecognised spelling means SDR, which is the safe direction: a
    /// signal nobody can name keeps today's behaviour instead of being tone
    /// mapped on a guess.
    @Test func anUnknownTransferMeansSDR() {
        #expect(SignalTransfer.resolved(nil) == .sdr)
        #expect(SignalTransfer.resolved("") == .sdr)
        #expect(SignalTransfer.resolved("slog3") == .sdr)
        #expect(SignalTransfer.resolved("pq") == .pq)
        #expect(SignalTransfer.resolved("hlg") == .hlg)
    }
}
