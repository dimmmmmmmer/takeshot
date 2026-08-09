import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// Capture bit depth, which is no longer a setting: it FOLLOWS THE SIGNAL.
///
/// The format-detection callback has always carried the source's own depth, and
/// the app used to fill that field in from the pixel format it had itself
/// requested — so it could state what it had asked for and never what had
/// arrived. There are two depths now, and this suite is mostly about keeping
/// them apart: what the WIRE is sending (`CaptureFormat.sourceBitDepth`) and
/// what the BOARD could actually be opened with (`CaptureFormat.bitDepth`).
///
/// The failure it exists to prevent is unchanged and only got easier to hit now
/// that nobody clicks anything: a 12-bit camera whose two extra bits quietly did
/// not make it, or a 12-bit capture nobody asked for landing in a 4:2:2 codec.
@MainActor
struct CaptureBitDepthTests {
    private static func signal(rgb444: Bool, bitDepth: Int,
                               source: Int? = nil) -> CaptureFormat {
        CaptureFormat(width: 1920, height: 1080, frameRate: 25, timecodeFPS: 25,
                      name: "1080p25", isRGB444: rgb444, bitDepth: bitDepth,
                      sourceBitDepth: source)
    }

    /// The two depths are separate fields, and the source's one is Optional
    /// because "the board did not say" is a real state — a forced input mode
    /// fires no detection callback at all.
    @Test func aFormatCarriesTheSignalsDepthAndTheBoardsSeparately() {
        let format: CaptureFormat = Self.signal(rgb444: true, bitDepth: 10,
                                                source: 12)
        #expect(format.sourceBitDepth == 12)
        #expect(format.bitDepth == 10)
        // and a format built without one says nothing rather than guessing 8
        let quiet: CaptureFormat = Self.signal(rgb444: true, bitDepth: 10)
        #expect(quiet.sourceBitDepth == nil)
        #expect(quiet.capturableBitDepth == nil)
    }

    /// The deepest capture a signal can yield, which is the sampling's rule and
    /// not the board's: RGB 4:4:4 gets whatever the source sends, YCbCr 4:2:2
    /// tops out at ten however deep the source is, because there is no 12-bit
    /// 4:2:2 wire format for the app to ask for.
    @Test func whatASignalCanYieldDependsOnItsSampling() {
        #expect(Self.signal(rgb444: true, bitDepth: 12, source: 12)
            .capturableBitDepth == 12)
        #expect(Self.signal(rgb444: true, bitDepth: 10, source: 10)
            .capturableBitDepth == 10)
        #expect(Self.signal(rgb444: true, bitDepth: 10, source: 8)
            .capturableBitDepth == 8)
        // 12-bit YCbCr: ten is all a 4:2:2 wire has, so ten is not a shortfall
        #expect(Self.signal(rgb444: false, bitDepth: 10, source: 12)
            .capturableBitDepth == 10)
        #expect(Self.signal(rgb444: false, bitDepth: 8, source: 8)
            .capturableBitDepth == 8)
    }

    /// What is worth saying about a signal's depth, as a value.
    @Test func theNoticeRuleSeparatesAShortfallFromADeepPath() {
        let hq: CaptureCodec = .proResHQ
        // the board could not keep up with the wire
        #expect(CaptureController.bitDepthNotice(
            format: Self.signal(rgb444: true, bitDepth: 10, source: 12),
            codec: hq) == CaptureController.BitDepthNotice.shortfall(
                source: 12, delivered: 10))
        // …and a 4:2:2 board that fell back to '2vuy' on a 10-bit wire
        #expect(CaptureController.bitDepthNotice(
            format: Self.signal(rgb444: false, bitDepth: 8, source: 10),
            codec: hq) == CaptureController.BitDepthNotice.shortfall(
                source: 10, delivered: 8))
        // a 12-bit YCbCr source captured as 'v210' is silence: the shortfall is
        // the wire format's and there is nothing the operator could do
        #expect(CaptureController.bitDepthNotice(
            format: Self.signal(rgb444: false, bitDepth: 10, source: 12),
            codec: hq) == nil)
        // the ordinary case says nothing at all
        #expect(CaptureController.bitDepthNotice(
            format: Self.signal(rgb444: true, bitDepth: 10, source: 10),
            codec: hq) == nil)
        // and a source the board did not describe cannot be measured
        #expect(CaptureController.bitDepthNotice(
            format: Self.signal(rgb444: true, bitDepth: 10), codec: hq) == nil)
    }

    /// A 12-bit capture nobody chose is announced, and the codec decides how
    /// much it has to say.
    ///
    /// This case exists BECAUSE depth follows the signal. 12-bit used to need a
    /// deliberate click, so the heaviest path in the app was always something
    /// the operator had already agreed to; a camera can now put them on it
    /// between setups, and 12-bit RGB 4:4:4 into a 4:2:2 codec is subsampled on
    /// the way into the file.
    @Test func aTwelveBitSignalNobodyAskedForIsAnnounced() {
        let twelve: CaptureFormat = Self.signal(rgb444: true, bitDepth: 12,
                                                source: 12)
        #expect(CaptureController.bitDepthNotice(format: twelve,
                                                 codec: .proRes4444)
            == CaptureController.BitDepthNotice.twelveBit(codec: .proRes4444))
        #expect(CaptureController.bitDepthNotice(format: twelve, codec: .proRes422)
            == CaptureController.BitDepthNotice.twelveBit(codec: .proRes422))
        // the words differ, and the 4:2:2 one names the codec that is losing it
        let kept: String = CaptureController.BitDepthNotice
            .twelveBit(codec: .proRes4444).localizedText
        let lost: String = CaptureController.BitDepthNotice
            .twelveBit(codec: .proRes422).localizedText
        #expect(kept != lost, "ProRes 4444 and ProRes 422 read the same")
        #expect(lost.contains("ProRes 422"), "message: \(lost)")
        #expect(!kept.contains("4:2:2"), "message: \(kept)")
    }

    /// The shortfall message carries both numbers, in the order the operator
    /// reads them: what the signal is, then what came back.
    @Test func theShortfallMessageCarriesBothDepths() {
        let text: String = CaptureController.BitDepthNotice
            .shortfall(source: 12, delivered: 10).localizedText
        #expect(text.contains("12"), "message: \(text)")
        #expect(text.contains("10"), "message: \(text)")
    }

    /// A board that could not keep up with the wire is reported to the operator.
    @Test func aShortfallIsReportedToTheOperator() async throws {
        try await ControllerHarness.run { controller, _ in
            // a BOARD is the source — the harness stands in for the demo source
            // under the "mock:" prefix, and the demo source never reports (see
            // below). There is no such backend, so the restart this triggers
            // fails; the notice it leaves is cleared next.
            controller.selectedDeviceID = "decklink:board"
            controller.lastError = nil
            // what the bridge reports after falling back to 'r210' on a 12-bit
            // signal
            controller.reportBitDepth(
                Self.signal(rgb444: true, bitDepth: 10, source: 12))
            let message: String = try #require(controller.lastError,
                                               "the fallback was silent")
            #expect(message.contains("12"), "message: \(message)")
            #expect(message.contains("10"), "message: \(message)")

            // …and a signal the board kept up with says nothing at all. A notice
            // on every format change would train the operator to ignore the one
            // that matters.
            controller.lastError = nil
            controller.reportBitDepth(
                Self.signal(rgb444: true, bitDepth: 10, source: 10))
            #expect(controller.lastError == nil)
            // nor does losing the signal entirely
            controller.reportBitDepth(nil)
            #expect(controller.lastError == nil)
        }
    }

    /// The demo source never reports on depth, whatever it happens to be.
    ///
    /// It generates an 8-bit signal by construction, describes no source depth
    /// at all, and nothing ever asked it for more — so the comparison is
    /// meaningless, and a notice nobody can act on, on every launch, is how an
    /// operator learns to ignore the banner that matters.
    @Test func theDemoSourceNeverReportsOnDepth() async throws {
        try await ControllerHarness.run { controller, _ in
            #expect(controller.isMockSelected,
                    "the harness is meant to stand in for the demo source")
            controller.lastError = nil
            // even handed a signal the rule WOULD have something to say about
            controller.reportBitDepth(
                Self.signal(rgb444: true, bitDepth: 10, source: 12))
            #expect(controller.lastError == nil,
                    "the demo source warned: \(controller.lastError ?? "")")
            #expect(CaptureController.bitDepthNotice(
                format: Self.signal(rgb444: true, bitDepth: 10, source: 12),
                codec: .proResHQ) != nil,
                "the silence is the source being excluded, not the arithmetic")
        }
    }

    /// Changing the CODEC while a 12-bit signal is live re-asks the question.
    ///
    /// The signal has not changed, so the format callback will not fire again —
    /// and the operator has just moved the only other term in the subsampling
    /// answer.
    @Test func switchingToAFourTwoTwoCodecOnATwelveBitSignalSaysSo() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.selectedDeviceID = "decklink:board"
            controller.signalFormat = Self.signal(rgb444: true, bitDepth: 12,
                                                  source: 12)
            controller.settings.capture.codec = .proRes4444
            controller.lastError = nil
            controller.settings.capture.codec = .proRes422
            let message: String = try #require(
                controller.lastError,
                "moving a 12-bit capture onto a 4:2:2 codec was silent")
            #expect(message.contains("ProRes 422"), "message: \(message)")
        }
    }

    /// ProRes 4444 is offered, and it is the only codec that can carry a 12-bit
    /// 4:4:4 source without subsampling it (measured in `TwelveBitRecordTests`).
    /// The notice above is the one place that reading is now acted on.
    @Test func proRes4444IsOfferedAndIsTheOnlyRGBCodec() {
        #expect(CaptureCodec.allCases.contains(.proRes4444))
        #expect(CaptureCodec.proRes4444.rawValue == "ProRes 4444")
        let rgbCapable: [CaptureCodec] = CaptureCodec.allCases
            .filter(\.isRGB444Capable)
        #expect(rgbCapable == [CaptureCodec.proRes4444])
    }
}
