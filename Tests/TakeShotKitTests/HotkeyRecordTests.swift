import AppKit
import Foundation
import Testing

@testable import TakeShotKit

/// **The stored hotkey record survives its own imperfections.**
///
/// It is one JSON dictionary in `UserDefaults`, unversioned, and it used to
/// be decoded as a whole: one malformed entry put EVERY action back on its
/// default with nothing said, and the next re-bind saved the reset. And an
/// update that ships a new default chord could land it on a chord the
/// operator had already bound — two actions on one key, fired in dictionary
/// order, which is the bug `HotkeyConflict` exists to make impossible.
@MainActor
struct HotkeyRecordTests {
    private static let recordKey = "TakeShot.Hotkeys"

    private func defaults(with record: [String: Any]) throws -> UserDefaults {
        let defaults = InMemoryDefaults()
        defaults.set(try JSONSerialization.data(withJSONObject: record),
                     forKey: Self.recordKey)
        return defaults
    }

    private func json(_ combo: KeyCombo) -> [String: Any] {
        var entry: [String: Any] = ["key": combo.key, "modifiers": combo.modifiers]
        if let keyCode = combo.keyCode { entry["keyCode"] = keyCode }
        return entry
    }

    @Test func oneMalformedEntryCostsOnlyItself() throws {
        let custom = KeyCombo(key: "r",
                              modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue,
                              keyCode: 15)
        let manager = HotkeyManager(defaults: try defaults(with: [
            HotkeyAction.toggleRecord.rawValue: json(custom),
            HotkeyAction.addMarker.rawValue: ["broken": true],
        ]))
        #expect(manager.combo(for: .toggleRecord) == custom,
                "one bad entry reset the operator's REC key")
        #expect(manager.combo(for: .addMarker) == HotkeyAction.addMarker.defaultCombo)
    }

    /// REC was put on ⌃D before the build that made ⌃D the dim default. The
    /// operator's binding keeps the chord; the newcomer comes up unbound
    /// rather than sharing it.
    @Test func aNewDefaultYieldsToTheOperatorsBinding() throws {
        let dim = HotkeyAction.toggleMonitorDim.defaultCombo
        let manager = HotkeyManager(defaults: try defaults(with: [
            HotkeyAction.toggleRecord.rawValue: json(dim),
        ]))
        let press = HotkeyPress(keyCode: dim.keyCode ?? 0,
                                modifiers: NSEvent.ModifierFlags(rawValue: dim.modifiers),
                                combo: dim, isTyping: false)
        #expect(manager.outcome(for: press, isPlaybackFullscreen: false,
                                isLiveFullscreen: false) == .perform(.toggleRecord),
                "the chord the operator bound answered to something else")
        #expect(manager.combo(for: .toggleMonitorDim).isUnbound,
                "two actions share \(dim.display)")
    }

    /// A REC bound on a Cyrillic layout is "в" with keyCode 2 — the same
    /// physical key as the dim default's "d". The yield compares chords the
    /// way `matches` fires them: by the key, not the symbol.
    @Test func aBindingRecordedOnAnotherLayoutStillOwnsItsKey() throws {
        let dim = HotkeyAction.toggleMonitorDim.defaultCombo
        let cyrillic = KeyCombo(key: "в", modifiers: dim.modifiers, keyCode: dim.keyCode)
        let manager = HotkeyManager(defaults: try defaults(with: [
            HotkeyAction.toggleRecord.rawValue: json(cyrillic),
        ]))
        #expect(manager.combo(for: .toggleMonitorDim).isUnbound,
                "⌃в and ⌃d are one key, and both answered to it")
        let press = HotkeyPress(keyCode: dim.keyCode ?? 0,
                                modifiers: NSEvent.ModifierFlags(rawValue: dim.modifiers),
                                combo: dim, isTyping: false)
        #expect(manager.outcome(for: press, isPlaybackFullscreen: false,
                                isLiveFullscreen: false) == .perform(.toggleRecord))
    }

    /// The ⌘⇧S → ⌘S grab-still migration moves a STORED entry; when the
    /// operator had already put their own binding on ⌘S it used to land on
    /// top of it — the collision the yield exists to prevent, made by the
    /// migration a line above it.
    @Test func theGrabStillMigrationYieldsToAChordTheOperatorOwns() throws {
        let oldGrab = KeyCombo(key: "s",
                               modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue,
                               keyCode: 1)
        let recOnCommandS = KeyCombo(key: "s", modifiers: NSEvent.ModifierFlags.command.rawValue,
                                     keyCode: 1)
        let manager = HotkeyManager(defaults: try defaults(with: [
            HotkeyAction.grabFrame.rawValue: json(oldGrab),
            HotkeyAction.toggleRecord.rawValue: json(recOnCommandS),
        ]))
        #expect(manager.combo(for: .grabFrame) == oldGrab,
                "the migration put grab-still on the operator's REC chord")
        #expect(manager.combo(for: .toggleRecord) == recOnCommandS)
    }

    /// Nothing stored, or a record with no collisions, leaves the defaults
    /// exactly as they ship — the yield is for the operator's chords only.
    @Test func defaultsAreNotYieldedToEachOther() throws {
        let manager = HotkeyManager(defaults: try defaults(with: [:]))
        for action in HotkeyAction.allCases {
            #expect(manager.combo(for: action) == action.defaultCombo,
                    "\(action) came up off its default")
        }
    }
}
