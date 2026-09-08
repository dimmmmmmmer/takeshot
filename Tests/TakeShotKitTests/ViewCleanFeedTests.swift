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

    /// **Every drawing of the rolling mark reads the one name.**
    ///
    /// The border and the label used to spell `isRecording && viewerMode ==
    /// .record` separately, in two files, which is how the clean feed came to
    /// hide one of them and not the other. Asserted on the source: a condition
    /// written at a surface is a condition the next surface writes slightly
    /// differently.
    ///
    /// It used to name the two files. Both drawings live in `PlayerArea` now —
    /// the label moved there because the clean-feed eye is mounted in its
    /// corner and was sitting on top of the words — so the walk is over the
    /// whole module instead: the rule is "nobody re-spells this", and pinning
    /// it to a file list is what made a legitimate move look like a failure.
    @Test func theRollingMarkIsSpelledOnceOnTheController() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TakeShotKit")
        let walker = try #require(FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil))
        var readers: [String] = []
        var files = 0
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard let raw = try? String(contentsOf: url, encoding: .utf8)
            else { continue }
            files += 1
            let code = raw.components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            if code.contains("controller.showsRecordingMark") {
                readers.append(url.lastPathComponent)
            }
            #expect(!code.contains("isRecording, controller.viewerMode == .record"),
                    Comment(rawValue: "\(url.lastPathComponent) spells the rolling condition itself again"))
        }
        try #require(files > 100, "the walk did not find the source tree")
        #expect(!readers.isEmpty, "nothing draws the rolling mark any more")
        #expect(readers.contains("PlayerArea.swift"),
                "the player no longer reads the shared rule: \(readers)")
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
