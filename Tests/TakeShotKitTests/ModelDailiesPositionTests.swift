import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// **The picker's choice has to survive the trip to the burn, and back.**
///
/// Four parallel fields carried through four hops — sheet → model → `burnins` →
/// settings → model again — is the shape where a copy-paste swap costs nothing
/// to write and shows up only on a delivered file: the operator moves the clip
/// name and the timecode moves instead. So every check here gives the four
/// lines FOUR DIFFERENT places, which is what makes a swap visible; giving two
/// of them the same place would pass with the fields crossed.
@MainActor @Suite struct ModelDailiesPositionTests {
    /// One place each, none of them the default for that line.
    private func moved(_ model: DailiesQueueModel) {
        model.timecodePosition = .bottomLeft
        model.clipNamePosition = .topRight
        model.projectPosition = .topCenter
        model.customPosition = .bottomRight
    }

    @Test func theModelHandsEachPlaceToItsOwnLine() {
        let model = DailiesQueueModel()
        moved(model)
        let burnins = model.burnins
        #expect(burnins.timecodePosition == .bottomLeft)
        #expect(burnins.clipNamePosition == .topRight)
        #expect(burnins.projectPosition == .topCenter)
        #expect(burnins.customPosition == .bottomRight)
    }

    @Test func aMovedLineIsStillThereNextTimeTheSheetOpens() async throws {
        try await ControllerHarness.run { controller, root in
            let model = DailiesQueueModel()
            moved(model)
            controller.rememberDailiesChoices(from: model)

            let reopened = DailiesQueueModel()
            reopened.prepare(takes: [], settings: controller.settings,
                             defaultFolder: root)
            #expect(reopened.timecodePosition == .bottomLeft)
            #expect(reopened.clipNamePosition == .topRight)
            #expect(reopened.projectPosition == .topCenter)
            #expect(reopened.customPosition == .bottomRight)
        }
    }

    /// The classic arrangement stores NOTHING — the project's convention for
    /// every added field, and the reason a settings blob written by an older
    /// build still decodes.
    @Test func theClassicArrangementIsNotWrittenDown() async throws {
        try await ControllerHarness.run { controller, root in
            controller.rememberDailiesChoices(from: DailiesQueueModel())
            #expect(controller.settings.dailies.timecodePosition == nil)
            #expect(controller.settings.dailies.clipNamePosition == nil)
            #expect(controller.settings.dailies.projectPosition == nil)
            #expect(controller.settings.dailies.customPosition == nil)

            // …and a blob with nothing in it still opens on the classic places.
            let fresh = DailiesQueueModel()
            fresh.prepare(takes: [], settings: controller.settings,
                          defaultFolder: root)
            #expect(fresh.timecodePosition == .topCenter)
            #expect(fresh.clipNamePosition == .bottomLeft)
            #expect(fresh.projectPosition == .bottomRight)
            #expect(fresh.customPosition == .topLeft)
        }
    }

    /// A blob naming a place that does not exist lands on the classic
    /// arrangement rather than drawing nothing — the reason the sheet reads
    /// through `…Effective` and never the raw strings.
    @Test func anUnknownPlaceFallsBackToTheClassicOne() {
        var dailies = DailiesSettings()
        dailies.timecodePosition = "middleOfNowhere"
        dailies.clipNamePosition = ""
        #expect(dailies.timecodePositionEffective == .topCenter)
        #expect(dailies.clipNamePositionEffective == .bottomLeft)
    }
}
