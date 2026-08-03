import CaptureCore
import Foundation
import Testing
@testable import TakeShotKit

/// What the scopes say a PQ or HLG trace means.
///
/// The trace itself does not move: an instrument plots the codes that arrived,
/// whatever curve they were encoded with. What HDR changes is the SCALE beside
/// it — and it has to, because "100 %" on a PQ waveform is a number with no
/// referent. The same trace height is 203 cd/m² or 4000 depending on nothing
/// the scale can show, so a percentage there is not a reading, it is a guess
/// the operator has no way to check.
struct HDRScopeAxisTests {
    /// Where 940 and 64 land on the 512-row trace map, the same wire range the
    /// SDR axis tests use.
    private static let wire = ScopeNominalRange(white: 41.0 / 511,
                                                black: 479.0 / 511)

    private func axis(_ transfer: SignalTransfer,
                      _ mode: ScopeScaleMode = .nits) -> ScopeAxis {
        ScopeAxis(nominal: Self.wire, mode: mode, transfer: transfer)
    }

    /// The nits ladder names luminances, and each one sits where its luminance
    /// sits on the wire's own signal scale — which for PQ is emphatically not a
    /// linear position. 203 cd/m² is 58 % of the code range, not 2 % of the way
    /// down from 10 000.
    @Test func theNitsLadderIsPlacedOnThePQCurve() throws {
        let ticks = axis(.pq).ticks
        let labels = ticks.map(\.label)
        #expect(labels.contains("203"), "no diffuse-white mark: \(labels)")
        #expect(labels.contains("26"), "no reference-grey mark: \(labels)")
        #expect(labels.contains("10000"), "no peak mark: \(labels)")
        #expect(labels.first == "10000", "the ladder is not top-first: \(labels)")
        #expect(labels.last == "0", "black is not at the bottom: \(labels)")
        // top of the canvas first, exactly like every other ladder
        #expect(ticks.map(\.unit) == ticks.map(\.unit).sorted())
        // and the two reference levels are the loud ones
        let white = try #require(ticks.first { $0.label == "203" })
        #expect(white.weight.opacity == ScopeTick.Weight.nominal.opacity)
    }

    /// The marks are placed by the transfer, so 203 cd/m² lands 58 % of the way
    /// up the wire's signal range rather than anywhere a percentage would put
    /// it. Checked against the axis's own level mapping.
    @Test func aNitsMarkSitsWhereItsSignalSits() throws {
        let axis = axis(.pq)
        let tick = try #require(axis.ticks.first { $0.label == "203" })
        let signal = try #require(
            SignalTransfer.pq.signal(forNits: HDRTransfer.referenceWhiteNits))
        #expect(abs(tick.unit - axis.unit(ofLevel: signal)) < 1e-9)
        // …and that is NOT where 100 % would put it
        #expect(abs(tick.unit - axis.unit(ofLevel: 1)) > 0.1)
    }

    /// An HLG scale stops at its reference display's 1000 cd/m². Printing 4000
    /// on it would put a number where the trace can never reach.
    @Test func anHLGScaleStopsAtItsReferenceDisplay() {
        let labels = axis(.hlg).ticks.map(\.label)
        #expect(labels.contains("1000"))
        #expect(!labels.contains("4000"), "HLG offered 4000 cd/m²: \(labels)")
        #expect(!labels.contains("10000"), "HLG offered 10 000: \(labels)")
    }

    /// The histogram's horizontal axis gets the same treatment, with fewer
    /// marks: a histogram is 256 bins wide in a box a couple of hundred points
    /// across, and a rule every decade turns it into a picket fence.
    @Test func theHistogramAxisIsTheSameLadderStoodOnItsSide() {
        let ticks = axis(.pq).horizontalTicks
        let labels = ticks.map(\.label)
        #expect(labels.contains("203"))
        #expect(labels.count <= 5, "too many marks for a histogram: \(labels)")
        #expect(ticks.map(\.unit) == ticks.map(\.unit).sorted())
    }

    /// Nits on an SDR frame falls back to percent rather than drawing a scale
    /// it cannot compute — which is what happens for one refresh every time an
    /// HDR camera is unplugged with the toolbar set to nits.
    @Test func nitsOnAnSDRFrameFallsBackToPercent() {
        #expect(ScopeScaleMode.resolved(.nits, transfer: .sdr) == .percent)
        #expect(ScopeScaleMode.resolved(.nits, transfer: .pq) == .nits)
        #expect(ScopeScaleMode.resolved(.percent, transfer: .pq) == .percent)
        #expect(ScopeScaleMode.resolved(.tenBitCode, transfer: .pq)
            == .tenBitCode)
        // the fallback path inside the axis itself, for the same reason
        let labels = axis(.sdr).ticks.map(\.label)
        #expect(labels.contains("100") && labels.contains("50"))
    }

    /// The two SDR scales are byte for byte what they were: an HDR-capable axis
    /// asked about an SDR frame draws the ladder that shipped.
    @Test func theSDRScalesAreUnchanged() {
        let percent = ScopeAxis(nominal: Self.wire, mode: .percent)
        #expect(percent.ticks.map(\.label)
            == axis(.sdr, .percent).ticks.map(\.label))
        let codes = ScopeAxis(nominal: Self.wire, mode: .tenBitCode)
        #expect(codes.ticks.map(\.label)
            == axis(.sdr, .tenBitCode).ticks.map(\.label))
        #expect(codes.horizontalTicks.map(\.label)
            == axis(.sdr, .tenBitCode).horizontalTicks.map(\.label))
    }

    /// The excursion bands are untouched by HDR, and that is the point of
    /// keeping levels and transfer as separate questions: a PQ signal over SDI
    /// is still studio swing, so the room above 100 % and below 0 % is where it
    /// always was.
    @Test func theExcursionBandsAreUnchangedByHDR() {
        let sdr = ScopeAxis(nominal: Self.wire, mode: .percent)
        let hdr = axis(.pq, .percent)
        #expect(sdr.excursionBands.map(\.from) == hdr.excursionBands.map(\.from))
        #expect(sdr.excursionBands.map(\.to) == hdr.excursionBands.map(\.to))
        #expect(!hdr.excursionBands.isEmpty)
    }
}
