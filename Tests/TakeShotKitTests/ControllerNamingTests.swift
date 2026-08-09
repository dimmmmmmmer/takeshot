import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// The naming fields under the player. Every value here ends up in a filename
/// on a card, so the regressions worth guarding are silent ones: a clip field
/// that loses its padding, a vendor preset that renumbers the roll wrongly, and
/// the rule the operator's brief states outright — changing the roll restarts
/// the clip numbering rather than continuing it.
@Suite @MainActor struct ControllerNamingTests {
    @Test func clipTextCarriesItsOwnPadding() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.commitClipText("0007")
            #expect(controller.nextTakeNumber == 7)
            #expect(controller.settings.naming.clipPadWidthEffective == 4)
            #expect(controller.clipDisplay == "0007")

            controller.commitClipText("12")
            #expect(controller.nextTakeNumber == 12)
            #expect(controller.clipDisplay == "12")

            // a single digit still gets the two-digit minimum
            controller.commitClipText("5")
            #expect(controller.nextTakeNumber == 5)
            #expect(controller.clipDisplay == "05")
        }
    }

    @Test func clipTextClampsInsteadOfOverflowingTheField() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.commitClipText("99999")
            #expect(controller.nextTakeNumber == 9999)
            #expect(controller.settings.naming.clipPadWidthEffective == 4)
        }
    }

    /// Typing over the field and deleting everything must not silently reset
    /// the clip number to zero mid-shift.
    @Test func nonNumericClipTextIsIgnored() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.commitClipText("0042")
            controller.commitClipText("")
            controller.commitClipText("abc")
            #expect(controller.nextTakeNumber == 42)
            #expect(controller.clipDisplay == "0042")
        }
    }

    @Test func vendorPresetRepadsTheRollNumberInPlace() async throws {
        try await ControllerHarness.run { controller, _ in
            let arri35 = try #require(
                NamingPreset.all.first { $0.key == "preset_arri35" })
            controller.roll = "1"
            controller.applyNamingPreset(arri35)
            #expect(controller.roll == "0001")
            #expect(controller.settings.naming.namingTemplate == arri35.template)
            #expect(controller.settings.naming.clipPadWidthEffective == 3)

            // a letter prefix on the roll survives the repad
            controller.roll = "A12"
            controller.applyNamingPreset(arri35)
            #expect(controller.roll == "A0012")
        }
    }

    /// The Sony Alpha preset has no roll convention at all — it must leave the
    /// operator's roll alone rather than zero-padding it to some default.
    @Test func aPresetWithoutRollDigitsLeavesTheRoll() async throws {
        try await ControllerHarness.run { controller, _ in
            let alpha = try #require(
                NamingPreset.all.first { $0.key == "preset_sony_alpha" })
            controller.roll = "B7"
            controller.applyNamingPreset(alpha)
            #expect(controller.roll == "B7")
            #expect(controller.settings.naming.clipPadWidthEffective == 4)
        }
    }

    @Test func rollAndCameraSteppersFollowTheFieldRules() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.roll = "009"
            controller.stepRoll(1)
            #expect(controller.roll == "010")
            controller.stepRoll(-1)
            #expect(controller.roll == "009")

            controller.settings.naming.cameraLabel = "A"
            controller.stepCamera(1)
            #expect(controller.settings.naming.cameraLabel == "B")
            controller.settings.naming.cameraLabel = "Z"
            controller.stepCamera(1)
            #expect(controller.settings.naming.cameraLabel == "A")
        }
    }

    /// "Changing the roll resets the clip number" — but only to the point the
    /// roll has actually reached, so swapping back to a half-shot roll
    /// continues it instead of overwriting C01.
    @Test func changingTheRollRenumbersFromThatRollsHighestClip() async throws {
        try await ControllerHarness.run { controller, root in
            controller.takes = [
                ControllerFixtures.take(named: "A002C007", in: root,
                                        roll: "002", clip: 7),
                ControllerFixtures.take(named: "A002C003", in: root,
                                        roll: "002", clip: 3),
                ControllerFixtures.take(named: "A001C011", in: root,
                                        roll: "001", clip: 11),
            ]

            controller.roll = "002"
            #expect(controller.nextTakeNumber == 8)

            // an untouched roll starts at one
            controller.roll = "003"
            #expect(controller.nextTakeNumber == 1)

            controller.roll = "001"
            #expect(controller.nextTakeNumber == 12)
        }
    }
}
