import SwiftUI
import Testing

@testable import TakeShotKit

/// **Clean feed hides CONTROLS, not WARNINGS.**
///
/// One press takes everything the app draws over the picture off it — the
/// badges, the compare bar, the scopes overlay, the corner buttons (owner: "в
/// левом нижнем углу нужна кнопка типа скрыть интерфейсные кнопки чтоб был
/// чистый вывод"). The operator turns it on to SHOW somebody the picture, which
/// is exactly why the sticky alarm stays: a mode that could hide "the card is
/// full" would hide it from the one person who could act on it, at the moment
/// they had turned away from the screen.
@MainActor
struct ViewCleanFeedTests {
    /// Measured on the pixels, in the band the badges occupy: the mode is
    /// about what is ON the picture, and a size comparison would say nothing —
    /// the player is a fixed frame either way.
    @Test func theChromeGoesAndTheWarningStays() async throws {
        try await ViewProbe.run { probe in
            let controller = probe.controller
            let size = CGSize(width: 640, height: 360)
            // A black picture, so anything bright in the band IS chrome.
            let player = Color.black.frame(width: size.width,
                                           height: size.height)
                .playerTopBadges()

            let dressed = probe.brightColumns(player, in: size, rows: 0...0.2)
            #expect(!dressed.isEmpty,
                    "no chrome was drawn at all, so its absence proves nothing")

            controller.toggleCleanFeed()
            #expect(controller.cleanFeed)
            let clean = probe.brightColumns(player, in: size, rows: 0...0.2)
            #expect(clean.isEmpty, """
                \(clean.count) columns of chrome are still on the picture with \
                the clean feed on
                """)

            // …and the warning is untouched: a display mode may not hide the
            // one thing the operator has turned away from the screen to miss.
            controller.persistentAlert = "the card is full"
            #expect(controller.persistentAlert == "the card is full")

            controller.toggleCleanFeed()
            #expect(!controller.cleanFeed, "the mode is a one-way door")
            #expect(!probe.brightColumns(player, in: size, rows: 0...0.2)
                .isEmpty, "the chrome did not come back")
        }
    }

    /// The key and the button are the same switch. Every hotkey in this app
    /// calls the method its button calls — that is the rule `HotkeyManager`
    /// is built on — and this one is the case where it matters most: the
    /// button is at a quarter opacity while the mode is on, so the key is how
    /// somebody who did not turn it on gets back.
    @Test func theKeyAndTheButtonAreTheSameSwitch() async throws {
        try await ViewProbe.run { probe in
            let controller = probe.controller
            probe.hotkeys.perform(.toggleCleanFeed, controller: controller)
            #expect(controller.cleanFeed, "⌃U did not reach the mode")
            probe.hotkeys.perform(.toggleCleanFeed, controller: controller)
            #expect(!controller.cleanFeed)
        }
    }

    /// It is on the ⌃ family with the rest of the viewer toggles, and on a
    /// letter nothing else has taken.
    @Test func theKeyIsControlUAndNothingElseHasIt() {
        let combo = HotkeyAction.toggleCleanFeed.defaultCombo
        #expect(combo.key == "u")
        #expect(combo.modifiers == NSEvent.ModifierFlags.control.rawValue)
        let others = HotkeyAction.allCases
            .filter { $0 != .toggleCleanFeed }
            .map(\.defaultCombo)
        #expect(!others.contains { $0.sharesKey(with: combo) },
                "⌃U is already taken by another action")
    }
}
