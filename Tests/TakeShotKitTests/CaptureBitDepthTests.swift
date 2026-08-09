import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// The capture bit-depth setting: what it resolves to, that it survives a save,
/// and that a request the board cannot meet is VISIBLE rather than silent.
///
/// 12-bit is a colour decision, so a fallback the operator is not told about is
/// the failure this suite exists to prevent: they select 12-bit, the hardware
/// or the mode cannot do it, and the takes come out 10-bit with nothing on
/// screen saying which.
@MainActor
struct CaptureBitDepthTests {
    /// The default is 10-bit and 12-bit is OFF, so installing an update never
    /// moves anybody onto a format their board may not deliver.
    @Test func theDefaultIsTenBitAndTwelveIsOff() {
        let fresh = CaptureSettings()
        #expect(fresh.capture.captureBitDepth == nil)
        #expect(fresh.capture.resolvedBitDepth == .ten)
    }

    /// Settings saved before `captureBitDepth` existed still resolve to the
    /// depth the operator had chosen — that is what the retired boolean is kept
    /// for, and it is read rather than rewritten.
    @Test func theLegacyBooleanStillDecidesWhenTheNewFieldIsAbsent() {
        var eightBit = CaptureSettings()
        eightBit.capture.tenBitCapture = false
        #expect(eightBit.capture.resolvedBitDepth == .eight)
        var tenBit = CaptureSettings()
        tenBit.capture.tenBitCapture = true
        #expect(tenBit.capture.resolvedBitDepth == .ten)
        // …and the explicit field wins over it, in both directions
        var conflicting = CaptureSettings()
        conflicting.capture.tenBitCapture = false
        conflicting.capture.captureBitDepth = CaptureBitDepth.twelve.rawValue
        #expect(conflicting.capture.resolvedBitDepth == .twelve)
    }

    /// An unrecognised stored value falls back rather than refusing to decode —
    /// a settings blob written by a newer build must not break capture.
    @Test func anUnknownStoredDepthFallsBack() {
        var settings = CaptureSettings()
        settings.capture.captureBitDepth = "14"
        #expect(settings.capture.resolvedBitDepth == .ten)
    }

    /// The setting round-trips through the stored JSON, which is where an
    /// added field that is not Optional would have broken every older blob.
    @Test func theSettingRoundTripsThroughStorage() throws {
        let defaults = InMemoryDefaults()
        var settings = CaptureSettings()
        settings.capture.captureBitDepth = CaptureBitDepth.twelve.rawValue
        settings.save(to: defaults)
        let loaded = CaptureSettings.loaded(from: defaults)
        #expect(loaded.capture.captureBitDepth == "12")
        #expect(loaded.capture.resolvedBitDepth == .twelve)
        // and an old blob with no such key still decodes
        let older = InMemoryDefaults()
        var legacy = CaptureSettings()
        legacy.capture.tenBitCapture = true
        legacy.save(to: older)
        #expect(CaptureSettings.loaded(from: older).capture.resolvedBitDepth == .ten)
    }

    /// Every case has a bit count, and they are the ones the pipeline branches
    /// on. A typo here would silently request the wrong format.
    @Test func theDepthsSayHowManyBitsTheyAre() {
        #expect(CaptureBitDepth.eight.bits == 8)
        #expect(CaptureBitDepth.ten.bits == 10)
        #expect(CaptureBitDepth.twelve.bits == 12)
        #expect(CaptureBitDepth.allCases.count == 3)
    }

    /// The same setting, asked about a YCbCr 4:2:2 source. 12 means 10 there —
    /// not a rounding-down of the wish but the truth about the wire: there is no
    /// 12-bit YCbCr format, so 'v210' is as deep as a 4:2:2 signal goes.
    @Test func theDepthsAlsoAnswerForAYCbCrWire() {
        #expect(CaptureBitDepth.eight.yuvBits == 8)
        #expect(CaptureBitDepth.ten.yuvBits == 10)
        #expect(CaptureBitDepth.twelve.yuvBits == 10)
        // and the shipped default asks for 10-bit on BOTH samplings
        #expect(CaptureSettings().capture.resolvedBitDepth.yuvBits == 10)
    }

    private static func signal(rgb444: Bool, bitDepth: Int) -> CaptureFormat {
        CaptureFormat(width: 1920, height: 1080, frameRate: 25, timecodeFPS: 25,
                      name: "1080p25", isRGB444: rgb444, bitDepth: bitDepth)
    }

    /// Which depth a signal is measured against, and whether it fell short.
    ///
    /// The YUV half is what the 10-bit YCbCr wave changed. This suite used to
    /// assert that a YUV signal could never fall short at all, on the stated
    /// grounds that "a YUV source is 8-bit '2vuy' by design and was never a
    /// request that could fail" — 'v210' is now the default request for a 4:2:2
    /// signal, so a board that delivers '2vuy' instead HAS fallen back.
    @Test func theShortfallRuleUsesTheDepthThatAppliesToTheSignal() {
        let twelve = CaptureBitDepth.twelve
        // RGB 4:4:4 measured against 12, and short at 10
        let rgbShort = CaptureController.bitDepthShortfall(
            format: Self.signal(rgb444: true, bitDepth: 10), requested: twelve)
        #expect(rgbShort?.requested == 12)
        #expect(rgbShort?.delivered == 10)
        #expect(CaptureController.bitDepthShortfall(
            format: Self.signal(rgb444: true, bitDepth: 12),
            requested: twelve) == nil, "a met request warned")
        // YCbCr 4:2:2 measured against 10 — asking for 12 on a 4:2:2 wire IS
        // asking for 10, so 'v210' delivered is silence and '2vuy' is not
        let yuvShort = CaptureController.bitDepthShortfall(
            format: Self.signal(rgb444: false, bitDepth: 8), requested: twelve)
        #expect(yuvShort?.requested == 10, "the YUV request is not 10-bit")
        #expect(yuvShort?.delivered == 8)
        #expect(CaptureController.bitDepthShortfall(
            format: Self.signal(rgb444: false, bitDepth: 10),
            requested: twelve) == nil, "v210 delivered, yet it warned")
        // …and an operator who chose 8-bit asked for what they got
        #expect(CaptureController.bitDepthShortfall(
            format: Self.signal(rgb444: false, bitDepth: 8),
            requested: .eight) == nil)
    }

    /// A board that delivered less than was asked for is reported, with both
    /// numbers in the message.
    @Test func aShortfallIsReportedToTheOperator() async throws {
        // both closures passed explicitly: a trailing closure alongside
        // `configure:` is two closures on one call, which the linter rejects
        try await ControllerHarness.run(
            configure: { $0.capture.captureBitDepth = CaptureBitDepth.twelve.rawValue },
            { controller, _ in
            // a BOARD is the source — the harness stands in for the demo source
            // under the "mock:" prefix, and the demo source never reports a
            // shortfall (see below). There is no such backend, so the restart
            // this triggers fails; the notice it leaves is cleared next.
            controller.selectedDeviceID = "decklink:board"
            controller.lastError = nil
            // what the bridge reports after falling back to 'r210'
            controller.reportBitDepthShortfall(
                Self.signal(rgb444: true, bitDepth: 10))
            let message = try #require(controller.lastError,
                                       "the fallback was silent")
            #expect(message.contains("12"), "message: \(message)")
            #expect(message.contains("10"), "message: \(message)")

            // …and a request that WAS met says nothing at all. A notice on every
            // format change would train the operator to ignore the one that
            // matters.
            controller.lastError = nil
            controller.reportBitDepthShortfall(
                Self.signal(rgb444: true, bitDepth: 12))
            #expect(controller.lastError == nil)
            // nor does losing the signal entirely
            controller.reportBitDepthShortfall(nil)
            #expect(controller.lastError == nil)
        })
    }

    /// The demo source never reports a shortfall, whatever the picker says.
    ///
    /// It generates an 8-bit signal by construction and nothing asked it for
    /// more, so the comparison is meaningless — and a notice nobody can act on,
    /// on every launch of `--demo`, is how an operator learns to ignore the
    /// banner that matters. The old RGB-only guard suppressed this by accident;
    /// now that a YUV signal IS measured, it has to be deliberate.
    @Test func theDemoSourceNeverReportsAShortfall() async throws {
        // both closures passed explicitly: a trailing closure alongside
        // `configure:` is two closures on one call, which the linter rejects
        try await ControllerHarness.run(
            configure: { $0.capture.captureBitDepth = CaptureBitDepth.twelve.rawValue },
            { controller, _ in
            #expect(controller.isMockSelected,
                    "the harness is meant to stand in for the demo source")
            controller.lastError = nil
            // the very format the demo generator reports, against a 12-bit ask
            controller.reportBitDepthShortfall(
                Self.signal(rgb444: false, bitDepth: 8))
            #expect(controller.lastError == nil,
                    "the demo source warned: \(controller.lastError ?? "")")
            // and the rule itself would have had something to say about it,
            // so the silence is the SOURCE being excluded and not the arithmetic
            #expect(CaptureController.bitDepthShortfall(
                format: Self.signal(rgb444: false, bitDepth: 8),
                requested: .twelve) != nil)
        })
    }

    /// The setting reaches the bridge: 12-bit asks for both RGB flags, 8-bit asks
    /// for none of the three. This is the wiring that decides which pixel format
    /// the board is actually opened with.
    @Test func theSettingReachesTheAdapter() {
        let adapter = DeckLinkBackendAdapter(watchesDevices: false)
        // the shipped defaults
        #expect(adapter.preferTenBitRGB, "10-bit RGB capture is the default")
        #expect(!adapter.preferTwelveBitRGB, "12-bit must be off by default")
        #expect(adapter.preferTenBitYUV, "10-bit YCbCr capture is the default")
        for (depth, ten, twelve) in [(CaptureBitDepth.eight, false, false),
                                     (.ten, true, false),
                                     (.twelve, true, true)] {
            var settings = CaptureSettings()
            settings.capture.captureBitDepth = depth.rawValue
            let resolved = settings.capture.resolvedBitDepth
            adapter.preferTenBitRGB = resolved != .eight
            adapter.preferTwelveBitRGB = resolved == .twelve
            adapter.preferTenBitYUV = resolved.yuvBits == 10
            #expect(adapter.preferTenBitRGB == ten, "\(depth) ten-bit flag")
            #expect(adapter.preferTwelveBitRGB == twelve, "\(depth) 12-bit flag")
            // 10-bit YCbCr is asked for at every depth except 8: there is no
            // 12-bit YCbCr format to ask for instead
            #expect(adapter.preferTenBitYUV == ten, "\(depth) ten-bit YUV flag")
        }
    }

    /// ProRes 4444 is offered, and it is the only codec that can carry a 12-bit
    /// 4:4:4 source without subsampling it (measured in `TwelveBitRecordTests`).
    @Test func proRes4444IsOfferedAndIsTheOnlyRGBCodec() {
        #expect(CaptureCodec.allCases.contains(.proRes4444))
        #expect(CaptureCodec.proRes4444.rawValue == "ProRes 4444")
        let rgbCapable = CaptureCodec.allCases.filter(\.isRGB444Capable)
        #expect(rgbCapable == [.proRes4444])
    }
}
