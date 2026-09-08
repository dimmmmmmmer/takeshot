import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// **The output name's two ends** (owner: "хотелось бы еще возможность
/// подредактировать название – префикс/суффикс").
///
/// The joined name is what reaches `appendingPathComponent`, and nothing on
/// that path sanitized it before: the take's own name came from
/// `NamingEngine`, which had already been through the rules, so
/// `take.displayName + "_DAILY"` was safe by inheritance. Two operator-typed
/// ends is where that stops being true.
@Suite @MainActor struct ModelDailiesNamingTests {
    @Test func theDefaultEndsProduceTheNameThisAppAlwaysWrote() {
        #expect(DailiesQueueModel.outputName(take: "A001C001", prefix: "",
                                             suffix: "_DAILY")
            == "A001C001_DAILY")
    }

    @Test func bothEndsLandWhereTheyAreTyped() {
        #expect(DailiesQueueModel.outputName(take: "A001C001",
                                             prefix: "REVIEW_",
                                             suffix: "_PROXY")
            == "REVIEW_A001C001_PROXY")
    }

    /// **A path separator in a name is a daily written somewhere else.**
    ///
    /// `NameField.prefix` is the rule for what a path component may hold, and
    /// the joined name goes through it — so "../" cannot climb out of the
    /// dailies folder and a "/" cannot invent a subfolder that nothing
    /// created.
    @Test func aSeparatorCannotEscapeTheDailiesFolder() {
        let escaped = DailiesQueueModel.outputName(
            take: "A001C001", prefix: "../../", suffix: "/etc")
        #expect(!escaped.contains("/"),
                "the name still holds a separator: \(escaped)")
        #expect(escaped == "A001C001etc", "got \(escaped)")
    }

    /// A name beginning with a dot is a file macOS hides, and the dailies the
    /// operator cannot find are the dailies that get shot again. Stripping the
    /// separators alone left "....A001C001" — which is what this test found.
    @Test func aDailyIsNeverAHiddenFile() {
        for prefix in ["...", ".", "..", ".hidden"] {
            let name = DailiesQueueModel.outputName(
                take: "A001C001", prefix: prefix, suffix: "")
            #expect(!name.hasPrefix("."), "\(prefix) produced \(name)")
        }
    }

    /// A name that sanitizes down to nothing falls back to the take's own
    /// name: a daily with no name is not a daily, and an empty component
    /// handed to `appendingPathComponent` is the dailies FOLDER.
    @Test func aNameThatSanitizesToNothingKeepsTheTakesOwnName() {
        #expect(DailiesQueueModel.outputName(take: "A001C001", prefix: "/",
                                             suffix: "") == "A001C001")
        #expect(DailiesQueueModel.outputName(take: "A001C001", prefix: "",
                                             suffix: "") == "A001C001")
    }

    /// The queue item carries the composed name, which is what the engine
    /// writes — the model's own preview and the file on disk are one string.
    @Test func theQueueItemCarriesTheComposedName() async throws {
        try await ControllerHarness.run { controller, root in
            let take = ControllerFixtures.take(named: "A001C007", in: root)
            let model = controller.dailies
            model.prepare(takes: [take], settings: controller.settings,
                          defaultFolder: root)
            model.namePrefix = "REVIEW_"
            model.nameSuffix = "_LT"
            let item = DailiesQueueModel.item(
                for: take, settings: controller.settings,
                prefix: model.namePrefix, suffix: model.nameSuffix)
            #expect(item.outputName == "REVIEW_A001C007_LT")
            #expect(model.outputName(for: "A001C007") == item.outputName,
                    "the sheet previews a name the run will not write")
        }
    }
}

/// The custom line's checkbox, and the thing it must not cost.
@Suite @MainActor struct ControllerDailiesCustomLineTests {
    @Test func theCustomLineSurvivesBeingSwitchedOff() async throws {
        try await ControllerHarness.run { controller, root in
            let model = controller.dailies
            model.prepare(takes: [], settings: controller.settings,
                          defaultFolder: root)
            model.customText = "INTERNAL - NOT FOR DISTRIBUTION"
            model.burnCustom = true
            controller.rememberDailiesChoices(from: model)

            // …now switched off, which used to be spelled "delete the text".
            model.burnCustom = false
            controller.rememberDailiesChoices(from: model)
            #expect(controller.settings.dailies.customText
                == "INTERNAL - NOT FOR DISTRIBUTION",
                    "the operator's sentence was thrown away")
            #expect(controller.settings.dailies.burnCustom == false)

            // …and the overlay draws no strip for it while it is off.
            #expect(model.burnins.customText.isEmpty)

            // …and it comes back with the words still there.
            model.prepare(takes: [], settings: controller.settings,
                          defaultFolder: root)
            #expect(!model.burnCustom)
            #expect(model.customText == "INTERNAL - NOT FOR DISTRIBUTION")
            model.burnCustom = true
            #expect(model.burnins.customText
                == "INTERNAL - NOT FOR DISTRIBUTION")
        }
    }

    /// The codec, the date's place and the two name ends persist like the rest
    /// of the convention — written on Start, nil at the default so an older
    /// build's blob still decodes.
    @Test func theNewChoicesPersistAndAreNilAtTheirDefaults() async throws {
        try await ControllerHarness.run { controller, root in
            let model = controller.dailies
            model.prepare(takes: [], settings: controller.settings,
                          defaultFolder: root)
            controller.rememberDailiesChoices(from: model)
            #expect(controller.settings.dailies.codec == nil)
            #expect(controller.settings.dailies.datePosition == nil)
            #expect(controller.settings.dailies.namePrefix == nil)
            #expect(controller.settings.dailies.nameSuffix == nil)

            model.codec = .proResLT
            model.datePosition = .topRight
            model.namePrefix = "REVIEW_"
            model.nameSuffix = "_LT"
            controller.rememberDailiesChoices(from: model)
            #expect(controller.settings.dailies.codec == "ProRes 422 LT")
            #expect(controller.settings.dailies.datePosition == "topRight")
            #expect(controller.settings.dailies.namePrefix == "REVIEW_")
            #expect(controller.settings.dailies.nameSuffix == "_LT")

            model.prepare(takes: [], settings: controller.settings,
                          defaultFolder: root)
            #expect(model.codec == .proResLT)
            #expect(model.datePosition == .topRight)
            #expect(model.namePrefix == "REVIEW_")
            #expect(model.nameSuffix == "_LT")
        }
    }

    /// The way back to the default destination is offered only when there is
    /// something to go back from — the rule the button's visibility asks.
    @Test func theDefaultFolderIsOfferedBackOnlyWhenAnOverrideIsInForce()
        async throws {
        try await ControllerHarness.run { controller, root in
            let model = controller.dailies
            model.prepare(takes: [], settings: controller.settings,
                          defaultFolder: root.appendingPathComponent("Dailies"))
            #expect(!controller.hasDailiesDestinationOverride)
            model.destination = URL(fileURLWithPath: "/Volumes/SSD1/Dailies")
            #expect(controller.hasDailiesDestinationOverride)
            controller.clearDailiesDestination()
            #expect(!controller.hasDailiesDestinationOverride)
        }
    }
}
