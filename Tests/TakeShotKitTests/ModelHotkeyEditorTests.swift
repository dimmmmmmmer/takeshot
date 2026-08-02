import AppKit
import Foundation
import Testing

@testable import TakeShotKit

/// The keyboard-shortcut editor, measured without a window.
///
/// The list used to be fifteen rows in the middle of the settings form and the
/// only logic in it was "overwrite whatever is there". Everything the editor
/// adds — the filter, the per-row reset, and above all the refusal to let two
/// actions answer to one chord — is model behaviour, so it is asserted here
/// rather than left to whoever next opens the sheet.
///
/// Every case gets its own defaults suite: a test must never write the
/// operator's real "TakeShot.Hotkeys" key.
@MainActor
struct ModelHotkeyEditorTests {
    private func withEditor(
        _ body: (HotkeyEditorModel, HotkeyManager) throws -> Void) throws {
        let defaults = InMemoryDefaults()
        let hotkeys = HotkeyManager(defaults: defaults)
        try body(HotkeyEditorModel(hotkeys: hotkeys), hotkeys)
    }

    /// A chord nothing in the app uses, so a test that assigns it is testing
    /// assignment rather than colliding by accident. ⌥⌘0 is not a default, not
    /// a fixed shortcut, and not a menu equivalent.
    private var freeCombo: KeyCombo {
        KeyCombo(key: "0", modifiers: NSEvent.ModifierFlags([.option, .command])
            .rawValue, keyCode: 29)
    }

    // MARK: - the list and its filter

    /// No query: every action, in declaration order. The operator learns where
    /// a row is, so the list must not sort itself by anything that moves.
    @Test func anEmptyQueryShowsEveryActionInOrder() throws {
        try withEditor { model, _ in
            #expect(model.rows == HotkeyAction.allCases)
            #expect(!model.isEmpty)
        }
    }

    /// Typing narrows the list by the action's localized title.
    @Test func theFilterMatchesTheLocalizedTitle() throws {
        try withEditor { model, _ in
            model.query = "marker"
            #expect(model.rows.contains(.addMarker))
            #expect(model.rows.contains(.removeMarker))
            #expect(!model.rows.contains(.toggleRecord),
                    "the record row survived a filter it does not match")
        }
    }

    /// …and by the chord, because half the time the operator is looking for
    /// "what is on ⌘R" rather than for a word.
    @Test func theFilterMatchesTheChordAsItIsDisplayed() throws {
        try withEditor { model, _ in
            model.query = "⌘R"
            #expect(model.rows == [.toggleRecord])
        }
    }

    /// Case and whitespace are the operator's, not the model's.
    @Test func theFilterIgnoresCaseAndSurroundingSpace() throws {
        try withEditor { model, _ in
            model.query = "  MARKER "
            #expect(model.rows.contains(.addMarker))
        }
    }

    /// A query nothing matches empties the list on purpose — the view says so
    /// rather than showing an unexplained blank.
    @Test func aQueryThatMatchesNothingEmptiesTheList() throws {
        try withEditor { model, _ in
            model.query = "zzzz-no-such-action"
            #expect(model.rows.isEmpty)
            #expect(model.isEmpty)
        }
    }

    // MARK: - assignment

    @Test func aFreeChordIsAssignedAndPersisted() throws {
        let defaults = InMemoryDefaults()
        let hotkeys = HotkeyManager(defaults: defaults)
        let combo = freeCombo

        #expect(hotkeys.assign(combo, to: .punchIn) == nil)
        #expect(hotkeys.combo(for: .punchIn) == combo)
        // through storage, because the editor's whole promise is that a binding
        // survives the way it always did
        #expect(HotkeyManager(defaults: defaults).combo(for: .punchIn) == combo)
    }

    /// The bug this exists to prevent: `install` fires the FIRST binding in a
    /// dictionary whose order is undefined, so a chord on two actions fires
    /// unpredictably. The second action does not get it, and the refusal names
    /// the one that has it.
    @Test func aChordAnotherActionOwnsIsRefusedAndTheOwnerNamed() throws {
        try withEditor { model, hotkeys in
            let recordCombo = HotkeyAction.toggleRecord.defaultCombo
            let before = hotkeys.combo(for: .punchIn)

            let conflict = hotkeys.assign(recordCombo, to: .punchIn)

            #expect(conflict == .action(.toggleRecord))
            #expect(hotkeys.combo(for: .punchIn) == before,
                    "the refused row moved anyway")
            #expect(hotkeys.combo(for: .toggleRecord) == recordCombo,
                    "the owner lost its own binding")
            let text = try #require(model.refusalText)
            #expect(text.contains(L(HotkeyAction.toggleRecord.titleKey)),
                    "the banner does not name the owner: \(text)")
        }
    }

    /// A fixed shortcut is refused too — AppKit answers ⌘, with Settings
    /// whatever the bindings say, so letting an action take it would produce a
    /// key that opens Settings and does nothing else.
    @Test func aFixedShortcutIsRefusedAndNamed() throws {
        try withEditor { model, hotkeys in
            let settingsChord = KeyCombo(
                key: ",", modifiers: NSEvent.ModifierFlags.command.rawValue,
                keyCode: 43)

            let conflict = hotkeys.assign(settingsChord, to: .punchIn)

            #expect(conflict == .reserved("reserved_settings"))
            #expect(hotkeys.combo(for: .punchIn) != settingsChord)
            let text = try #require(model.refusalText)
            #expect(text.contains(L("reserved_settings")))
        }
    }

    /// Rebinding an action to the chord it already has is not a conflict with
    /// itself.
    @Test func anActionMayBeReassignedItsOwnChord() throws {
        try withEditor { _, hotkeys in
            let own = HotkeyAction.punchIn.defaultCombo
            #expect(hotkeys.assign(own, to: .punchIn) == nil)
            #expect(hotkeys.combo(for: .punchIn) == own)
        }
    }

    /// Two bindings on the same physical key differing only by a stored keyCode
    /// still collide when the operator presses it, so the check is on key +
    /// modifiers — not on the whole struct.
    @Test func aLegacyComboWithoutAKeyCodeStillCollides() throws {
        try withEditor { _, hotkeys in
            let record = HotkeyAction.toggleRecord.defaultCombo
            let sameChordNoKeyCode = KeyCombo(key: record.key,
                                              modifiers: record.modifiers,
                                              keyCode: nil)
            #expect(hotkeys.conflict(for: sameChordNoKeyCode, assigning: .punchIn)
                == .action(.toggleRecord))
        }
    }

    /// A successful assignment clears the previous refusal: the banner belongs
    /// to the attempt that caused it.
    @Test func aSuccessfulAssignmentClearsTheBanner() throws {
        try withEditor { model, hotkeys in
            hotkeys.assign(HotkeyAction.toggleRecord.defaultCombo, to: .punchIn)
            #expect(model.refusalText != nil)

            hotkeys.assign(freeCombo, to: .punchIn)
            #expect(model.refusalText == nil)
        }
    }

    // MARK: - reset

    @Test func resettingOneRowLeavesTheOthersAlone() throws {
        try withEditor { model, hotkeys in
            hotkeys.assign(freeCombo, to: .punchIn)
            let otherCombo = KeyCombo(
                key: "9", modifiers: NSEvent.ModifierFlags.option.rawValue,
                keyCode: 25)
            hotkeys.assign(otherCombo, to: .grabFrame)
            #expect(model.isCustomized(.punchIn))

            model.reset(.punchIn)

            #expect(hotkeys.combo(for: .punchIn)
                == HotkeyAction.punchIn.defaultCombo)
            #expect(!model.isCustomized(.punchIn))
            #expect(hotkeys.combo(for: .grabFrame) == otherCombo,
                    "resetting one row reset another")
            #expect(model.isCustomized(.grabFrame))
        }
    }

    /// Reset must work even when the default is currently held by another
    /// action — refusing there would leave the operator with no way back.
    @Test func resetWorksEvenWhenAnotherActionSitsOnTheDefault() throws {
        try withEditor { model, hotkeys in
            // move punch-in off Z, then park grab-still ON Z
            hotkeys.assign(freeCombo, to: .punchIn)
            #expect(hotkeys.assign(HotkeyAction.punchIn.defaultCombo,
                                   to: .grabFrame) == nil)

            model.reset(.punchIn)

            #expect(hotkeys.combo(for: .punchIn)
                == HotkeyAction.punchIn.defaultCombo)
        }
    }

    @Test func resetAllPutsEveryRowBack() throws {
        try withEditor { model, hotkeys in
            hotkeys.assign(freeCombo, to: .punchIn)
            hotkeys.assign(HotkeyAction.toggleRecord.defaultCombo, to: .grabFrame)

            model.resetAll()

            for action in HotkeyAction.allCases {
                #expect(hotkeys.combo(for: action) == action.defaultCombo)
                #expect(!model.isCustomized(action))
            }
            #expect(model.refusalText == nil)
        }
    }

    // MARK: - recording state

    /// The chord button toggles capture, and a second click on the same row
    /// stops it rather than leaving the app swallowing keys.
    @Test func theChordButtonTogglesRecordingForItsOwnRow() throws {
        try withEditor { model, hotkeys in
            model.toggleRecording(.punchIn)
            #expect(model.isRecording(.punchIn))
            #expect(model.isRecording)

            model.toggleRecording(.punchIn)
            #expect(!model.isRecording(.punchIn))
            #expect(hotkeys.recordingAction == nil)
        }
    }

    /// Starting a capture drops the previous refusal — the operator is acting
    /// on it, so the banner has said what it had to say.
    @Test func startingACaptureClearsTheBanner() throws {
        try withEditor { model, hotkeys in
            hotkeys.assign(HotkeyAction.toggleRecord.defaultCombo, to: .punchIn)
            #expect(model.refusalText != nil)

            model.toggleRecording(.punchIn)
            #expect(model.refusalText == nil)
        }
    }

    /// Moving capture to another row leaves exactly one row capturing.
    @Test func onlyOneRowCapturesAtATime() throws {
        try withEditor { model, _ in
            model.toggleRecording(.punchIn)
            model.toggleRecording(.grabFrame)
            #expect(!model.isRecording(.punchIn))
            #expect(model.isRecording(.grabFrame))
        }
    }
}
