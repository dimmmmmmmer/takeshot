import AppKit
import Foundation

/// Stores bindings and locally intercepts keys within the app.
///
/// Split out of `Hotkeys.swift`, which holds the combo and the action list;
/// what each action DOES is `HotkeyManager+Actions`.
@MainActor
final class HotkeyManager: ObservableObject {
    @Published private(set) var bindings: [HotkeyAction: KeyCombo]
    /// The action currently recording a new combo (UI state).
    @Published var recordingAction: HotkeyAction?
    /// The last assignment that was refused, and who owns the chord. Published
    /// so the editor can say WHICH action already has it — a refusal with no
    /// name reads as the app ignoring the keypress.
    @Published private(set) var lastRefusal: (action: HotkeyAction,
                                              conflict: HotkeyConflict)?

    private var monitor: Any?
    /// Injectable so tests get their own suite instead of the operator's
    /// bindings; production always uses the standard defaults.
    private let defaults: UserDefaults
    private static let defaultsKey = "TakeShot.Hotkeys"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let stored = try? JSONDecoder().decode([String: KeyCombo].self, from: data) {
            var result: [HotkeyAction: KeyCombo] = [:]
            for action in HotkeyAction.allCases {
                result[action] = stored[action.rawValue] ?? action.defaultCombo
            }
            // grab-still default moved ⌘⇧S → ⌘S: migrate an untouched binding
            let oldGrabDefault = KeyCombo(
                key: "s", modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue,
                keyCode: 1)
            if result[.grabFrame] == oldGrabDefault {
                result[.grabFrame] = HotkeyAction.grabFrame.defaultCombo
            }
            bindings = result
        } else {
            bindings = Dictionary(uniqueKeysWithValues:
                HotkeyAction.allCases.map { ($0, $0.defaultCombo) })
        }
    }

    func combo(for action: HotkeyAction) -> KeyCombo {
        bindings[action] ?? action.defaultCombo
    }

    func set(_ combo: KeyCombo, for action: HotkeyAction) {
        bindings[action] = combo
        let stored = Dictionary(uniqueKeysWithValues:
            bindings.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    func resetToDefaults() {
        for action in HotkeyAction.allCases {
            set(action.defaultCombo, for: action)
        }
        lastRefusal = nil
    }

    /// Put `action` back on the key it ships with.
    ///
    /// Not guarded by the conflict check: a default cannot collide with a fixed
    /// shortcut (`ModelHotkeyTests` proves that), and if it collides with a
    /// chord the operator moved onto it, refusing would leave them with no way
    /// back at all.
    func resetToDefault(_ action: HotkeyAction) {
        set(action.defaultCombo, for: action)
        if lastRefusal?.action == action { lastRefusal = nil }
    }

    /// Whether `action` is still on the key it ships with.
    func isCustomized(_ action: HotkeyAction) -> Bool {
        combo(for: action) != action.defaultCombo
    }

    /// What already answers to `combo`, ignoring `action`'s own binding — a
    /// chord is never in conflict with itself.
    func conflict(for combo: KeyCombo,
                  assigning action: HotkeyAction) -> HotkeyConflict? {
        if let reserved = ReservedShortcut.owning(combo) {
            return .reserved(reserved.titleKey)
        }
        // key + modifiers, not the whole combo: two bindings on the same
        // physical key differing only by a stored keyCode still collide when
        // the operator presses it.
        let owner = HotkeyAction.allCases.first { other in
            other != action && self.combo(for: other).key == combo.key
                && self.combo(for: other).modifiers == combo.modifiers
        }
        return owner.map { .action($0) }
    }

    /// Bind `combo` to `action` unless something already owns it.
    ///
    /// Returns the owner it refused for, nil on success. This is the funnel every
    /// surface goes through — the editor and the key-recording monitor both —
    /// so there is one answer to "can two actions share a chord": no.
    @discardableResult
    func assign(_ combo: KeyCombo, to action: HotkeyAction) -> HotkeyConflict? {
        if let conflict = conflict(for: combo, assigning: action) {
            lastRefusal = (action, conflict)
            return conflict
        }
        lastRefusal = nil
        set(combo, for: action)
        return nil
    }

    /// Drop the refusal banner (the editor clears it when the operator moves on).
    func clearRefusal() { lastRefusal = nil }

    /// While a text field owns the keyboard, only ⌘ combos reach the hotkeys —
    /// the macOS convention (menu shortcuts work mid-typing). Bare keys are the
    /// field's letters; ⌃ combos are the field's own Emacs-style edit bindings
    /// (⌃A line start, ⌃D delete forward…), and a ⌃ hotkey family that stole
    /// them typed dim/mute into the operator's naming instead of editing it.
    nonisolated static func typingKeepsTheKey(modifiers: NSEvent.ModifierFlags,
                                              isTyping: Bool) -> Bool {
        isTyping && !modifiers.contains(.command)
    }

    /// Intercept keys in all app windows (not system-global).
    func install(controller: CaptureController) {
        controller.hotkeysRef = self
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak controller] event in
            guard let self, let controller else { return event }

            // Esc closes the player fullscreens
            if event.keyCode == 53, controller.isPlaybackFullscreen {
                controller.togglePlaybackFullscreen()
                return nil
            }
            if event.keyCode == 53, controller.isLiveFullscreen {
                controller.toggleLiveFullscreen()
                return nil
            }

            // a new combo is being recorded in settings
            if let recording = self.recordingAction {
                if event.keyCode == 53 { // Esc — cancel
                    self.recordingAction = nil
                    return nil
                }
                if let combo = KeyCombo.from(event: event) {
                    // refused chords leave the row where it was and put the
                    // owner's name on screen; the recording stops either way,
                    // so the operator is never stuck capturing keys
                    self.assign(combo, to: recording)
                    self.recordingAction = nil
                    return nil
                }
                return nil
            }

            let isTyping = event.window?.firstResponder is NSTextView
            if Self.typingKeepsTheKey(modifiers: event.modifierFlags,
                                      isTyping: isTyping) {
                return event
            }

            for (action, combo) in self.bindings where combo.matches(event: event) {
                self.perform(action, controller: controller)
                return nil
            }
            return event
        }
    }
}
