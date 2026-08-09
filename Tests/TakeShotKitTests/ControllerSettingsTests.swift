import CaptureCore
import Foundation
import SwiftUI
import Testing

@testable import TakeShotKit

/// Settings do not just hold values — writing one fans out into the rest of the
/// app (persist, relist the library, re-arm the folder watcher, restart
/// capture). The fan-out is deliberately partial for speed, which is exactly
/// where a change stops taking effect without anyone noticing. These pin the
/// parts that are observable without hardware: persistence, the two resets, and
/// the destination change that has to wipe the library.
@Suite @MainActor struct ControllerSettingsTests {
    @Test func everySettingsWriteReachesTheStore() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.settings.naming.projectName = "Nightfall"
            controller.settings.naming.cameraLabel = "C"

            let reloaded = CaptureSettings.loaded(from: controller.defaults)
            #expect(reloaded.naming.projectName == "Nightfall")
            #expect(reloaded.naming.cameraLabel == "C")
        }
    }

    /// The factory reset exists to rescue a mangled configuration mid-shift —
    /// taking the day's record folder with it would lose the library too.
    @Test func factoryResetKeepsTheRecordFolder() async throws {
        try await ControllerHarness.run { controller, root in
            controller.settings.naming.projectName = "Nightfall"
            controller.settings.naming.cameraLabel = "D"
            controller.settings.naming.postfix = "night"
            controller.panelSide = "left"
            controller.takes = [ControllerFixtures.take(named: "A001C001", in: root)]

            controller.resetAllSettings()

            #expect(controller.settings.capture.destinationPath == root.path)
            #expect(controller.settings.naming.projectName.isEmpty)
            #expect(controller.settings.naming.cameraLabel == "A")
            #expect(controller.settings.naming.postfix == nil)
            #expect(controller.panelSide == "right")
            // the destination did not change, so the library must survive
            #expect(controller.takes.count == 1)
        }
    }

    @Test func interfaceResetTouchesOnlyTheColors() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.settings.naming.projectName = "Nightfall"
            controller.settings.theme.appearance = "dark"
            controller.settings.theme.playerBackgroundHex = "#123456"
            controller.settings.theme.appBackgroundHex = "#654321"
            controller.settings.theme.accentHex = "#ABCDEF"
            controller.panelSide = "left"

            controller.resetInterface()

            #expect(controller.settings.theme.playerBackgroundHex == nil)
            #expect(controller.settings.theme.appBackgroundHex == nil)
            #expect(controller.settings.theme.accentHex == nil)
            #expect(controller.settings.theme.appearance == nil)
            #expect(controller.panelSide == "right")
            #expect(controller.settings.naming.projectName == "Nightfall")
        }
    }

    @Test func themeMapsToAColorScheme() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.settings.theme.appearance = "light"
            #expect(controller.colorScheme == .light)
            controller.settings.theme.appearance = "dark"
            #expect(controller.colorScheme == .dark)
            controller.settings.theme.appearance = nil
            #expect(controller.colorScheme == nil)
            // anything unrecognized follows the system rather than crashing
            controller.settings.theme.appearance = "sepia"
            #expect(controller.colorScheme == nil)
        }
    }

    @Test func colorPickersRoundTripThroughHex() async throws {
        try await ControllerHarness.run { controller, _ in
            // defaults when nothing is stored
            #expect(controller.playerBackground.hexString == "#000000")
            #expect(controller.accentColor.hexString == "#FFFFFF")
            #expect(controller.appBackground.hexString == "#262626")

            controller.playerBackground = try #require(Color(hex: "#204060"))
            controller.accentColor = try #require(Color(hex: "#FF8800"))
            controller.appBackground = try #require(Color(hex: "#101010"))

            #expect(controller.settings.theme.playerBackgroundHex == "#204060")
            #expect(controller.settings.theme.accentHex == "#FF8800")
            #expect(controller.settings.theme.appBackgroundHex == "#101010")
            #expect(controller.playerBackground.hexString == "#204060")
        }
    }

    /// A new record folder is a new day's library: leaving the previous
    /// folder's takes in the panel is how a take gets renumbered on top of an
    /// existing file.
    @Test func aNewDestinationEmptiesTheLibrary() async throws {
        try await ControllerHarness.run { controller, root in
            controller.takes = [
                ControllerFixtures.take(named: "A001C001", in: root),
                ControllerFixtures.take(named: "A001C002", in: root, clip: 2),
            ]
            controller.nextTakeNumber = 3
            controller.otherFiles = [root.appendingPathComponent("foreign.mp4")]
            let generation = controller.libraryGeneration

            let second = root.appendingPathComponent("second-card")
            try FileManager.default.createDirectory(
                at: second, withIntermediateDirectories: true)
            controller.settings.capture.destinationPath = second.path

            #expect(controller.takes.isEmpty)
            #expect(controller.otherFiles.isEmpty)
            #expect(controller.retiredTakes.isEmpty)
            #expect(controller.nextTakeNumber == 1)
            #expect(controller.libraryGeneration > generation)
            #expect(controller.destinationRoot.path == second.path)
        }
    }

    /// nil means "all channels", including any that appear later on a bigger
    /// board — storing an explicit all-ones mask would freeze the count.
    @Test func anAllOnAudioMaskIsStoredAsNil() async throws {
        try await ControllerHarness.run { controller, _ in
            #expect(controller.settings.audio.audioChannelMask == nil)
            #expect(controller.isChannelEnabled(0))
            #expect(controller.isChannelEnabled(15))

            controller.toggleAudioChannel(3)
            #expect(controller.settings.audio.audioChannelMask != nil)
            #expect(!controller.isChannelEnabled(3))
            #expect(controller.isChannelEnabled(2))

            controller.toggleAudioChannel(3)
            #expect(controller.settings.audio.audioChannelMask == nil)
            #expect(controller.isChannelEnabled(3))
        }
    }

    @Test func languageChoiceRoundTripsThroughSettings() async throws {
        try await ControllerHarness.run { controller, _ in
            #expect(controller.appLanguage == .english)
            controller.appLanguage = .russian
            #expect(controller.settings.theme.appLanguage == "ru")
            #expect(controller.appLanguage == .russian)
            controller.appLanguage = .english
            #expect(controller.appLanguage == .english)
        }
        L10n.apply(.english) // leave the process on a known language
    }
}
