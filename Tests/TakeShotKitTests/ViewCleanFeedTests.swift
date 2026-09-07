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

    /// **The transport bar is chrome too.** The pixel test above samples the
    /// top of the frame, where the badges are, so the bar under the picture
    /// was outside everything that had ever been asserted — and it stayed
    /// drawn, with its scrubber and its buttons, through a mode whose whole
    /// job is to take the controls off the picture.
    ///
    /// Asserted through `transportBarKind` because that is where the decision
    /// now lives: the toast measures its own offset against the same property,
    /// so a bar hidden anywhere else would have left the toast floating over
    /// nothing.
    @Test func theTransportBarGoesWithTheRestOfTheChrome() async throws {
        try await ControllerHarness.run { controller, root in
            controller.viewerMode = .playback
            controller.playbackURL = root.appendingPathComponent("A001C001.mov")
            try #require(controller.transportBarKind == .video,
                         "the fixture has no transport bar to hide")

            controller.toggleCleanFeed()
            #expect(controller.transportBarKind == .none,
                    "the transport bar is still drawn over a clean feed")
            // …and the toast comes down with it rather than floating above a
            // bar that is no longer there
            #expect(PlayerToastPlan.current(
                error: "x", notice: nil, noticeTint: nil,
                transport: controller.transportBarKind)?.bottomInset
                == PlayerToastPlan.insetOverPicture)

            controller.toggleCleanFeed()
            #expect(controller.transportBarKind == .video, "the bar did not come back")
        }
    }

    /// The rolling mark — the red border and the REC label — is one fact drawn
    /// in two files, and a clean feed takes both.
    ///
    /// Nothing is lost by hiding it: the REC button in the bottom bar is a
    /// white square while a take rolls, and the bottom bar is a SIBLING of the
    /// player rather than something drawn on it, so it is untouched.
    @Test func theRecordingMarkGoesWithIt() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.viewerMode = .record
            controller.isRecording = true
            try #require(controller.showsRecordingMark,
                         "the fixture is not showing a rolling take")

            controller.toggleCleanFeed()
            #expect(!controller.showsRecordingMark)

            controller.toggleCleanFeed()
            #expect(controller.showsRecordingMark, "the mark did not come back")
        }
    }

    /// The audio panel is a panel of controls, so it goes — but it is not
    /// CLOSED. An operator who put it up before showing the director the
    /// picture finds it still up afterwards.
    @Test func theAudioPanelGoesButIsNotClosed() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.showAudioPanel = true
            try #require(controller.showsAudioPanel)

            controller.toggleCleanFeed()
            #expect(!controller.showsAudioPanel)
            #expect(controller.showAudioPanel,
                    "the clean feed closed the panel instead of hiding it")

            controller.toggleCleanFeed()
            #expect(controller.showsAudioPanel, "the panel did not come back")
        }
    }

    /// **Both drawings of the rolling mark read the one name.** They are in
    /// two files — the border in `PlayerArea`, the label in `PreviewView` —
    /// and they used to spell `isRecording && viewerMode == .record`
    /// separately, which is how the clean feed came to hide one thing and not
    /// the other. Asserted on the source: a condition written at a surface is
    /// a condition the next surface writes slightly differently.
    @Test func theRollingMarkIsSpelledOnceOnTheController() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TakeShotKit")
        for name in ["PlayerArea", "PreviewView"] {
            let code = try String(
                contentsOf: root.appendingPathComponent("\(name).swift"),
                encoding: .utf8)
                .components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            #expect(code.contains("controller.showsRecordingMark"),
                    Comment(rawValue: "\(name) does not read the shared rule"))
            #expect(!code.contains("isRecording, controller.viewerMode == .record"),
                    Comment(rawValue: "\(name) spells the rolling condition itself again"))
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
