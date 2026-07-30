import AppKit
import Foundation
import Testing
@testable import TakeShotKit

/// Hotkeys are matched on the PHYSICAL key so a Cyrillic layout keeps working —
/// the operator on set switches layout to type a Russian scene note and then
/// hits the record key. Matching on the produced character instead silently
/// disables every shortcut the moment the layout changes, which is exactly the
/// kind of failure that gets noticed one take too late.
struct ModelHotkeyTests {
    private func event(_ characters: String, keyCode: UInt16,
                       modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode))
    }

    // MARK: - matching

    /// keyCode 15 is the physical R key; on a Russian layout it produces "к".
    @Test func matchesThePhysicalKeyWhateverTheLayoutProduces() throws {
        let combo = HotkeyAction.toggleRecord.defaultCombo // ⌘R, keyCode 15
        #expect(combo.matches(event: try event("r", keyCode: 15,
                                               modifiers: .command)))
        #expect(combo.matches(event: try event("к", keyCode: 15,
                                               modifiers: .command)))
        // the same character on a different physical key is NOT the shortcut
        #expect(!combo.matches(event: try event("r", keyCode: 3,
                                                modifiers: .command)))
    }

    @Test func modifiersMustMatchExactly() throws {
        let combo = HotkeyAction.toggleRecord.defaultCombo // ⌘R
        #expect(!combo.matches(event: try event("r", keyCode: 15)))
        #expect(!combo.matches(event: try event("r", keyCode: 15,
                                                modifiers: [.command, .shift])))
        #expect(!combo.matches(event: try event("r", keyCode: 15,
                                                modifiers: .option)))
    }

    /// M and ⇧M are two different actions, so the shift bit alone has to
    /// separate them.
    @Test func shiftAloneSeparatesAddAndRemoveMarker() throws {
        let add = HotkeyAction.addMarker.defaultCombo
        let remove = HotkeyAction.removeMarker.defaultCombo
        let plain = try event("m", keyCode: 46)
        let shifted = try event("M", keyCode: 46, modifiers: .shift)
        #expect(add.matches(event: plain))
        #expect(!add.matches(event: shifted))
        #expect(remove.matches(event: shifted))
        #expect(!remove.matches(event: plain))
    }

    /// Caps Lock, Fn and the numeric-pad bit ride along on real keyboards and
    /// must not break a shortcut.
    @Test func irrelevantModifierBitsAreIgnored() throws {
        let combo = HotkeyAction.toggleRecord.defaultCombo
        #expect(combo.matches(event: try event(
            "r", keyCode: 15, modifiers: [.command, .capsLock, .function])))

        let bare = HotkeyAction.fullscreen.defaultCombo // F, no modifiers
        #expect(bare.matches(event: try event("f", keyCode: 3,
                                              modifiers: .capsLock)))
    }

    /// Bindings saved before `keyCode` existed have to keep working; they can
    /// only be matched by the produced character.
    @Test func legacyCombosWithoutAKeyCodeFallBackToTheSymbol() throws {
        let legacy = KeyCombo(key: "r", modifiers: NSEvent.ModifierFlags.command.rawValue,
                              keyCode: nil)
        #expect(legacy.matches(event: try event("r", keyCode: 15,
                                                modifiers: .command)))
        // …and on a Cyrillic layout they no longer match — which is the reason
        // keyCode was added, not something to "fix" by loosening the compare
        #expect(!legacy.matches(event: try event("к", keyCode: 15,
                                                 modifiers: .command)))
    }

    // MARK: - recording a new combo

    @Test func recordingNormalizesTheKeyAndKeepsThePhysicalCode() throws {
        let combo = try #require(KeyCombo.from(event: try event(
            "G", keyCode: 5, modifiers: [.command, .shift])))
        #expect(combo.key == "g")
        #expect(combo.keyCode == 5)
        #expect(combo.modifiers
                == NSEvent.ModifierFlags([.command, .shift]).rawValue)
    }

    @Test func recordingNamesTheThreeSpecialKeys() throws {
        #expect(KeyCombo.from(event: try event(" ", keyCode: 49))?.key == "space")
        #expect(KeyCombo.from(event: try event("\r", keyCode: 36))?.key == "return")
        #expect(KeyCombo.from(event: try event("\u{1b}", keyCode: 53))?.key
                == "escape")
    }

    /// A Tab or a dead key produces nothing bindable; recording one would eat
    /// keyboard navigation in the settings sheet forever.
    @Test func whitespaceKeysAreNotBindable() throws {
        #expect(KeyCombo.from(event: try event("\t", keyCode: 48)) == nil)
    }

    @Test func displayShowsModifiersInTheMacOrder() {
        let all = KeyCombo(key: "s", modifiers: NSEvent.ModifierFlags(
            [.control, .option, .shift, .command]).rawValue, keyCode: 1)
        #expect(all.display == "⌃⌥⇧⌘S")
        #expect(HotkeyAction.toggleRecord.defaultCombo.display == "⌘R")
        #expect(HotkeyAction.fullscreen.defaultCombo.display == "F")
        #expect(KeyCombo(key: "space", modifiers: 0, keyCode: 49).display
                == "Space")
        #expect(KeyCombo(key: "return", modifiers: 0, keyCode: 36).display == "↩")
        #expect(KeyCombo(key: "escape", modifiers: 0, keyCode: 53).display == "⎋")
    }

    @Test func combosSurviveTheJSONRoundTripTheyArePersistedWith() throws {
        let original = HotkeyAction.grabFrame.defaultCombo
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(KeyCombo.self, from: data) == original)
    }

    // MARK: - the default set

    /// `install` walks the bindings dictionary and fires the first action whose
    /// combo matches. Dictionary order is not defined, so two actions sharing a
    /// combo would fire unpredictably — REC one day, grab-still the next.
    @Test func noTwoActionsShareADefaultCombo() {
        let actions = HotkeyAction.allCases
        for (index, action) in actions.enumerated() {
            let display = action.defaultCombo.display
            for other in actions[(index + 1)...]
            where action.defaultCombo == other.defaultCombo {
                Issue.record("\(action) and \(other) both default to \(display)")
            }
        }
    }

    /// The bindings the app hands AppKit as key equivalents are not all in
    /// `HotkeyAction`: Settings, the folder, Help, the reveal item and the
    /// transport's Space/Esc are fixed shortcuts on their own views. A default
    /// that lands on one of those is a key the operator presses expecting one
    /// thing and gets the other, and no test over `allCases` alone would see it.
    @Test func noDefaultCollidesWithAFixedShortcut() {
        let command = NSEvent.ModifierFlags.command.rawValue
        let commandShift = NSEvent.ModifierFlags([.command, .shift]).rawValue
        // key + modifiers only: what AppKit matches a key equivalent on
        let fixed: [(String, UInt)] = [
            (",", command),          // Settings (AppCommands)
            ("o", commandShift),     // open the record folder (AppCommands)
            ("?", command),          // Help (AppCommands)
            ("return", command),     // rename a take (TakeRowControls)
            ("space", 0),            // play/pause (TransportBar, RawTransportBar)
            ("escape", 0),           // close an overlay (AudioChannelPanel)
        ]
        for action in HotkeyAction.allCases {
            let combo = action.defaultCombo
            for (key, modifiers) in fixed
            where combo.key == key && combo.modifiers == modifiers {
                Issue.record("""
                    \(action) defaults to \(combo.display), which is already a \
                    fixed shortcut
                    """)
            }
        }
    }

    /// Every action needs a label in the Settings list; a missing string shows
    /// the raw key to the operator.
    @Test func everyActionHasATitleInBothLanguages() throws {
        let bundle = Bundle.module
        for language in ["en", "ru"] {
            let path = try #require(bundle.path(forResource: language,
                                                ofType: "lproj"))
            let strings = try #require(NSDictionary(
                contentsOfFile: path + "/Localizable.strings") as? [String: String])
            let missing = HotkeyAction.allCases
                .map(\.titleKey)
                .filter { strings[$0] == nil }
            #expect(missing.isEmpty,
                    "\(language) is missing \(missing.joined(separator: ", "))")
        }
    }

    /// The raw values are the persisted keys — `circleLastTake` is deliberately
    /// still named that way so saved bindings keep resolving after the "good
    /// take" rename.
    @Test func actionRawValuesAreTheStableStorageKeys() {
        #expect(Set(HotkeyAction.allCases.map(\.rawValue)) == [
            "toggleRecord", "circleLastTake", "badTakeLast", "fullscreen",
            "grabFrame", "instantReplay", "addMarker", "removeMarker", "punchIn",
            "toggleScopesOverlay", "toggleLUTPreview", "toggleMonitorMute",
            "toggleMonitorDim", "toggleViewerMode", "toggleAudioChannelBank",
        ])
    }

    /// The viewer and monitoring toggles are one family on ⌃, and two of them
    /// (the scopes overlay, the preview LUT) sit on menu items — a bare letter
    /// there would show no shortcut at all in the menu bar.
    @Test func theViewerAndMonitoringTogglesAreOneControlFamily() {
        let control = NSEvent.ModifierFlags.control.rawValue
        let expected: [HotkeyAction: String] = [
            .toggleScopesOverlay: "s",
            .toggleLUTPreview: "l",
            .toggleMonitorMute: "a",
            .toggleMonitorDim: "d",
            .toggleViewerMode: "v",
            .toggleAudioChannelBank: "i",
        ]
        for (action, key) in expected {
            let combo = action.defaultCombo
            #expect(combo.key == key, "\(action) defaults to \(combo.display)")
            #expect(combo.modifiers == control,
                    "\(action) is not on ⌃: \(combo.display)")
            #expect(combo.keyCode != nil,
                    "\(action) has no physical key, so a Cyrillic layout loses it")
        }
    }
}

/// Binding storage. A test suite must never write the operator's real
/// "TakeShot.Hotkeys" key, so each case runs against its own defaults suite.
@MainActor
struct ModelHotkeyStorageTests {
    private func withSuite(_ body: (UserDefaults) throws -> Void) throws {
        let name = "TakeShot.tests.hotkeys.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            Issue.record("could not create a defaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: name)
            UserDefaults.standard.removeSuite(named: name)
        }
        try body(defaults)
    }

    private func store(_ bindings: [HotkeyAction: KeyCombo],
                       in defaults: UserDefaults) throws {
        let keyed = Dictionary(uniqueKeysWithValues:
            bindings.map { ($0.key.rawValue, $0.value) })
        defaults.set(try JSONEncoder().encode(keyed), forKey: "TakeShot.Hotkeys")
    }

    @Test func emptyStorageYieldsTheDefaultBindings() throws {
        try withSuite { defaults in
            let manager = HotkeyManager(defaults: defaults)
            for action in HotkeyAction.allCases {
                #expect(manager.combo(for: action) == action.defaultCombo)
            }
        }
    }

    @Test func aChangedBindingIsPersistedAndReloaded() throws {
        try withSuite { defaults in
            let custom = KeyCombo(key: "p", modifiers: 0, keyCode: 35)
            HotkeyManager(defaults: defaults).set(custom, for: .toggleRecord)

            let reloaded = HotkeyManager(defaults: defaults)
            #expect(reloaded.combo(for: .toggleRecord) == custom)
            // the untouched actions are still on their defaults
            #expect(reloaded.combo(for: .grabFrame)
                    == HotkeyAction.grabFrame.defaultCombo)
        }
    }

    /// Every action in the Settings list is remappable, not just the ones a
    /// test happened to name: the list is built from `allCases`, so an action
    /// whose binding did not survive the round trip would show the operator a
    /// combo the app no longer answers to.
    @Test func everyActionCanBeReboundAndComesBack() throws {
        try withSuite { defaults in
            // ⌥ + a key nothing else uses, one per action: distinct combos, so a
            // binding landing on the wrong action fails here rather than merging
            // invisibly into the right answer
            let option = NSEvent.ModifierFlags.option.rawValue
            let custom = Dictionary(uniqueKeysWithValues:
                HotkeyAction.allCases.enumerated().map { index, action in
                    (action, KeyCombo(key: "\(index % 10)", modifiers: option,
                                      keyCode: UInt16(100 + index)))
                })
            let manager = HotkeyManager(defaults: defaults)
            for (action, combo) in custom { manager.set(combo, for: action) }

            let reloaded = HotkeyManager(defaults: defaults)
            for action in HotkeyAction.allCases {
                #expect(reloaded.combo(for: action) == custom[action],
                        "\(action.rawValue) did not survive the round trip")
            }
        }
    }

    /// A saved blob written before an action existed must not leave that action
    /// unbound — every release that adds a hotkey hits this path.
    @Test func anActionMissingFromStorageFallsBackToItsDefault() throws {
        try withSuite { defaults in
            try store([.toggleRecord: KeyCombo(key: "p", modifiers: 0, keyCode: 35)],
                      in: defaults)
            let manager = HotkeyManager(defaults: defaults)
            #expect(manager.combo(for: .punchIn)
                    == HotkeyAction.punchIn.defaultCombo)
            #expect(manager.combo(for: .toggleRecord).key == "p")
        }
    }

    /// Grab-still moved from ⌘⇧S to ⌘S. An operator who never rebound it should
    /// end up on the new default rather than keeping a combo that is no longer
    /// documented anywhere.
    @Test func theUntouchedGrabStillBindingIsMigrated() throws {
        try withSuite { defaults in
            let oldDefault = KeyCombo(
                key: "s",
                modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue,
                keyCode: 1)
            try store([.grabFrame: oldDefault], in: defaults)

            let manager = HotkeyManager(defaults: defaults)
            #expect(manager.combo(for: .grabFrame)
                    == HotkeyAction.grabFrame.defaultCombo)
            #expect(manager.combo(for: .grabFrame) != oldDefault)
        }
    }

    /// …but a binding the operator actually chose is theirs, even if it happens
    /// to use the same key.
    @Test func aDeliberatelyReboundGrabStillIsLeftAlone() throws {
        try withSuite { defaults in
            let chosen = KeyCombo(key: "s",
                                  modifiers: NSEvent.ModifierFlags.option.rawValue,
                                  keyCode: 1)
            try store([.grabFrame: chosen], in: defaults)
            #expect(HotkeyManager(defaults: defaults).combo(for: .grabFrame)
                    == chosen)
        }
    }

    @Test func resetRestoresEveryDefaultAndPersistsIt() throws {
        try withSuite { defaults in
            let manager = HotkeyManager(defaults: defaults)
            manager.set(KeyCombo(key: "p", modifiers: 0, keyCode: 35),
                        for: .toggleRecord)
            manager.set(KeyCombo(key: "q", modifiers: 0, keyCode: 12),
                        for: .punchIn)
            manager.resetToDefaults()

            for action in HotkeyAction.allCases {
                #expect(manager.combo(for: action) == action.defaultCombo)
            }
            let reloaded = HotkeyManager(defaults: defaults)
            #expect(reloaded.combo(for: .toggleRecord)
                    == HotkeyAction.toggleRecord.defaultCombo)
        }
    }

    /// Corrupt storage must not take the app's whole hotkey set with it.
    @Test func unreadableStorageFallsBackToTheDefaults() throws {
        try withSuite { defaults in
            defaults.set(Data("not json".utf8), forKey: "TakeShot.Hotkeys")
            let manager = HotkeyManager(defaults: defaults)
            #expect(manager.combo(for: .toggleRecord)
                    == HotkeyAction.toggleRecord.defaultCombo)
        }
    }
}
