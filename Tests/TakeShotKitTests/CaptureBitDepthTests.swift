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
        #expect(fresh.captureBitDepth == nil)
        #expect(fresh.resolvedCaptureBitDepth == .ten)
    }

    /// Settings saved before `captureBitDepth` existed still resolve to the
    /// depth the operator had chosen — that is what the retired boolean is kept
    /// for, and it is read rather than rewritten.
    @Test func theLegacyBooleanStillDecidesWhenTheNewFieldIsAbsent() {
        var eightBit = CaptureSettings()
        eightBit.tenBitCapture = false
        #expect(eightBit.resolvedCaptureBitDepth == .eight)
        var tenBit = CaptureSettings()
        tenBit.tenBitCapture = true
        #expect(tenBit.resolvedCaptureBitDepth == .ten)
        // …and the explicit field wins over it, in both directions
        var conflicting = CaptureSettings()
        conflicting.tenBitCapture = false
        conflicting.captureBitDepth = CaptureBitDepth.twelve.rawValue
        #expect(conflicting.resolvedCaptureBitDepth == .twelve)
    }

    /// An unrecognised stored value falls back rather than refusing to decode —
    /// a settings blob written by a newer build must not break capture.
    @Test func anUnknownStoredDepthFallsBack() {
        var settings = CaptureSettings()
        settings.captureBitDepth = "14"
        #expect(settings.resolvedCaptureBitDepth == .ten)
    }

    /// The setting round-trips through the stored JSON, which is where an
    /// added field that is not Optional would have broken every older blob.
    @Test func theSettingRoundTripsThroughStorage() throws {
        let defaults = InMemoryDefaults()
        var settings = CaptureSettings()
        settings.captureBitDepth = CaptureBitDepth.twelve.rawValue
        settings.save(to: defaults)
        let loaded = CaptureSettings.loaded(from: defaults)
        #expect(loaded.captureBitDepth == "12")
        #expect(loaded.resolvedCaptureBitDepth == .twelve)
        // and an old blob with no such key still decodes
        let older = InMemoryDefaults()
        var legacy = CaptureSettings()
        legacy.tenBitCapture = true
        legacy.save(to: older)
        #expect(CaptureSettings.loaded(from: older).resolvedCaptureBitDepth == .ten)
    }

    /// Every case has a bit count, and they are the ones the pipeline branches
    /// on. A typo here would silently request the wrong format.
    @Test func theDepthsSayHowManyBitsTheyAre() {
        #expect(CaptureBitDepth.eight.bits == 8)
        #expect(CaptureBitDepth.ten.bits == 10)
        #expect(CaptureBitDepth.twelve.bits == 12)
        #expect(CaptureBitDepth.allCases.count == 3)
    }

    /// A board that delivered less than was asked for is reported.
    @Test func aShortfallIsReportedToTheOperator() async throws {
        // both closures passed explicitly: a trailing closure alongside
        // `configure:` is two closures on one call, which the linter rejects
        try await ControllerHarness.run(
            configure: { $0.captureBitDepth = CaptureBitDepth.twelve.rawValue },
            { controller, _ in
            controller.lastError = nil
            // what the bridge reports after falling back to 'r210'
            controller.reportBitDepthShortfall(
                CaptureFormat(width: 1920, height: 1080, frameRate: 25,
                              timecodeFPS: 25, name: "1080p25",
                              isRGB444: true, bitDepth: 10))
            let message = try #require(controller.lastError,
                                       "the fallback was silent")
            #expect(message.contains("12"), "message: \(message)")
            #expect(message.contains("10"), "message: \(message)")
        })
    }

    /// …and a request that WAS met says nothing at all. A notice on every format
    /// change would train the operator to ignore the one that matters.
    @Test func meetingTheRequestIsSilent() async throws {
        // both closures passed explicitly: a trailing closure alongside
        // `configure:` is two closures on one call, which the linter rejects
        try await ControllerHarness.run(
            configure: { $0.captureBitDepth = CaptureBitDepth.twelve.rawValue },
            { controller, _ in
            controller.lastError = nil
            controller.reportBitDepthShortfall(
                CaptureFormat(width: 1920, height: 1080, frameRate: 25,
                              timecodeFPS: 25, name: "1080p25",
                              isRGB444: true, bitDepth: 12))
            #expect(controller.lastError == nil)
        })
    }

    /// A YUV signal is 8-bit '2vuy' by design and was never a request that
    /// could fail, so it must not produce a notice either — otherwise every
    /// operator shooting YUV gets a warning they cannot act on.
    @Test func aYuvSignalIsNotAShortfall() async throws {
        // both closures passed explicitly: a trailing closure alongside
        // `configure:` is two closures on one call, which the linter rejects
        try await ControllerHarness.run(
            configure: { $0.captureBitDepth = CaptureBitDepth.twelve.rawValue },
            { controller, _ in
            controller.lastError = nil
            controller.reportBitDepthShortfall(
                CaptureFormat(width: 1920, height: 1080, frameRate: 25,
                              timecodeFPS: 25, name: "1080p25",
                              isRGB444: false, bitDepth: 8))
            #expect(controller.lastError == nil)
            // …and neither does losing the signal entirely
            controller.reportBitDepthShortfall(nil)
            #expect(controller.lastError == nil)
        })
    }

    /// The setting reaches the bridge: 12-bit asks for both flags, 8-bit asks
    /// for neither. This is the wiring that decides which pixel format the
    /// board is actually opened with.
    @Test func theSettingReachesTheAdapter() {
        let adapter = DeckLinkBackendAdapter(watchesDevices: false)
        // the shipped default, unchanged
        #expect(adapter.preferTenBitRGB, "10-bit RGB capture is the default")
        #expect(!adapter.preferTwelveBitRGB, "12-bit must be off by default")
        for (depth, ten, twelve) in [(CaptureBitDepth.eight, false, false),
                                     (.ten, true, false),
                                     (.twelve, true, true)] {
            var settings = CaptureSettings()
            settings.captureBitDepth = depth.rawValue
            adapter.preferTenBitRGB = settings.resolvedCaptureBitDepth != .eight
            adapter.preferTwelveBitRGB = settings.resolvedCaptureBitDepth == .twelve
            #expect(adapter.preferTenBitRGB == ten, "\(depth) ten-bit flag")
            #expect(adapter.preferTwelveBitRGB == twelve, "\(depth) 12-bit flag")
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
