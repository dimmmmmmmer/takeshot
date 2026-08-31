import Testing

@testable import TakeShotKit

/// What the filter indicator is allowed to say about the picture.
///
/// `PlaybackLook` exists so that "the icon is lit" and "a look is on the frame"
/// cannot come apart — it was extracted after they had. This suite is the
/// fifth fact arriving.
@MainActor
struct ModelPlaybackLookTests {
    /// Difference mode is a MEASUREMENT, and the indicator has to say so.
    ///
    /// Both engines read the two halves at the pre-LUT stage and never put the
    /// |A−B| output through the cube — a difference of two graded pictures is
    /// not the difference being measured. The pixels were always right; the
    /// icon lit in the accent colour over a frame with no look on it, which is
    /// how it was reported (owner: "в режиме дифф лут не применяется" — the
    /// picture is correct and deliberate; the icon was lying about it).
    @Test func aBypassedLookIsPickedAndNotEngaged() {
        let look = PlaybackLook.current(previewEnabled: true, hasCube: true,
                                        fileHasBakedLook: false,
                                        suppressed: false,
                                        compareBypassesLook: true)
        #expect(look == .bypassed)
        #expect(!look.isEngaged, "the icon would light over a picture with no look")
        #expect(!look.appliesCube, "the tap would be handed a cube to ignore")
        // …and it is still a PRESSABLE state, which `PlaybackLookButton`
        // decides in an exhaustive switch: the look is still picked, and
        // pressing it is how the operator says what they want on leaving
        // difference mode.
        #expect(look != .baked,
                "a bypassed look reads as baked — the bar would stop offering it")
    }

    /// The order matters at both ends. A baked file carries the look in its own
    /// codes whatever the compare is doing, and a look already switched off is
    /// not additionally "bypassed" — that would be two answers to one question.
    @Test func bakedOutranksItAndSuppressedIsNotIt() {
        #expect(PlaybackLook.current(previewEnabled: true, hasCube: true,
                                     fileHasBakedLook: true, suppressed: false,
                                     compareBypassesLook: true) == .baked)
        #expect(PlaybackLook.current(previewEnabled: true, hasCube: true,
                                     fileHasBakedLook: false, suppressed: true,
                                     compareBypassesLook: true) == .suppressed)
    }

    /// …and with no compare on screen nothing changed: the default keeps every
    /// existing caller answering exactly what it did.
    @Test func withNoCompareTheAnswerIsUnchanged() {
        #expect(PlaybackLook.current(previewEnabled: true, hasCube: true,
                                     fileHasBakedLook: false,
                                     suppressed: false) == .applied)
        #expect(PlaybackLook.current(previewEnabled: false, hasCube: true,
                                     fileHasBakedLook: false,
                                     suppressed: false) == .none)
    }

    /// Only difference bypasses it. Wipe, blend and side-by-side all show
    /// PICTURES, and a picture on this app's viewer goes through the look.
    @Test func onlyDifferenceBypassesTheLook() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.viewerMode = .record
            controller.referencePinned = true
            for mode in [CaptureController.CompareMode.off, .wipe, .blend,
                         .sideBySide] {
                controller.compareMode = mode
                #expect(!controller.compareBypassesLook,
                        "\(mode) claimed to bypass the look")
            }
            controller.compareMode = .difference
            #expect(controller.compareBypassesLook)
            // …and with nothing to difference against, both engines fall
            // through and apply the look after all, so saying "bypassed" there
            // would be the same lie pointing the other way.
            controller.referencePinned = false
            #expect(!controller.compareBypassesLook,
                    "difference with no B side still claimed to bypass")
        }
    }
}
