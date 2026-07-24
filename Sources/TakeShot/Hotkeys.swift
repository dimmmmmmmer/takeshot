import AppKit
import Foundation

/// A key combo: a symbol + modifiers.
struct KeyCombo: Codable, Equatable {
    var key: String        // symbol for display ("r", "space", "return")
    var modifiers: UInt    // NSEvent.ModifierFlags.rawValue (deviceIndependent)
    /// Physical key: we match on it so hotkeys work on any keyboard layout.
    var keyCode: UInt16?

    var display: String {
        var parts = ""
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        if flags.contains(.control) { parts += "⌃" }
        if flags.contains(.option) { parts += "⌥" }
        if flags.contains(.shift) { parts += "⇧" }
        if flags.contains(.command) { parts += "⌘" }
        let names = ["space": "Space", "return": "↩", "escape": "⎋"]
        return parts + (names[key] ?? key.uppercased())
    }

    static func from(event: NSEvent) -> KeyCombo? {
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .intersection([.command, .option, .control, .shift])
        var key: String
        switch event.keyCode {
        case 49: key = "space"
        case 36: key = "return"
        case 53: key = "escape"
        default:
            guard let chars = event.charactersIgnoringModifiers?.lowercased(),
                  let first = chars.first, !first.isWhitespace else { return nil }
            key = String(first)
        }
        return KeyCombo(key: key, modifiers: flags.rawValue, keyCode: event.keyCode)
    }

    func matches(event: NSEvent) -> Bool {
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .intersection([.command, .option, .control, .shift])
        guard flags.rawValue == modifiers else { return false }
        if let keyCode {
            // by physical key — the keyboard layout doesn't matter (same key in Latin/Cyrillic)
            return event.keyCode == keyCode
        }
        // old saved combos without a keyCode — by symbol
        return Self.from(event: event)?.key == key
    }
}

/// Actions that hotkeys can be bound to.
enum HotkeyAction: String, CaseIterable, Codable, Identifiable {
    case toggleRecord
    case circleLastTake   // good take (legacy key name — for saved settings)
    case badTakeLast
    case fullscreen
    case grabFrame
    case instantReplay
    case addMarker

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .toggleRecord: return "hotkey_record"
        case .circleLastTake: return "hotkey_good"
        case .badTakeLast: return "hotkey_bad"
        case .fullscreen: return "hotkey_fullscreen"
        case .grabFrame: return "hotkey_grab"
        case .instantReplay: return "hotkey_replay"
        case .addMarker: return "hotkey_marker"
        }
    }

    var defaultCombo: KeyCombo {
        switch self {
        case .toggleRecord:
            return KeyCombo(key: "r", modifiers: NSEvent.ModifierFlags.command.rawValue,
                            keyCode: 15)
        case .circleLastTake:
            return KeyCombo(key: "g", modifiers: NSEvent.ModifierFlags.command.rawValue,
                            keyCode: 5)
        case .badTakeLast:
            return KeyCombo(key: "b", modifiers: NSEvent.ModifierFlags.command.rawValue,
                            keyCode: 11)
        case .fullscreen:
            return KeyCombo(key: "f", modifiers: 0, keyCode: 3)
        case .grabFrame:
            // ⌘⇧S — grab still
            return KeyCombo(key: "s",
                            modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue,
                            keyCode: 1)
        case .instantReplay:
            // ⌘E — replay the last take
            return KeyCombo(key: "e", modifiers: NSEvent.ModifierFlags.command.rawValue,
                            keyCode: 14)
        case .addMarker:
            // M — flag the moment (NLE convention)
            return KeyCombo(key: "m", modifiers: 0, keyCode: 46)
        }
    }
}

/// Stores bindings and locally intercepts keys within the app.
@MainActor
final class HotkeyManager: ObservableObject {
    @Published private(set) var bindings: [HotkeyAction: KeyCombo]
    /// The action currently recording a new combo (UI state).
    @Published var recordingAction: HotkeyAction?

    private var monitor: Any?
    private static let defaultsKey = "TakeShot.Hotkeys"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let stored = try? JSONDecoder().decode([String: KeyCombo].self, from: data) {
            var result: [HotkeyAction: KeyCombo] = [:]
            for action in HotkeyAction.allCases {
                result[action] = stored[action.rawValue] ?? action.defaultCombo
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
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    func resetToDefaults() {
        for action in HotkeyAction.allCases {
            set(action.defaultCombo, for: action)
        }
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
                    self.set(combo, for: recording)
                    self.recordingAction = nil
                    return nil
                }
                return nil
            }

            // don't intercept text-field typing if the combo has no ⌘/⌃
            let flags = event.modifierFlags.intersection([.command, .control])
            let isTyping = event.window?.firstResponder is NSTextView
            if isTyping && flags.isEmpty {
                return event
            }

            for (action, combo) in self.bindings where combo.matches(event: event) {
                self.perform(action, controller: controller)
                return nil
            }
            return event
        }
    }

    private func perform(_ action: HotkeyAction, controller: CaptureController) {
        switch action {
        case .toggleRecord:
            if controller.isCapturing { controller.toggleManualRecord() }
        case .circleLastTake:
            controller.toggleLastRating(.good)
        case .badTakeLast:
            controller.toggleLastRating(.bad)
        case .fullscreen:
            if controller.viewerMode == .playback, controller.playbackURL != nil {
                controller.togglePlaybackFullscreen()
            } else {
                controller.toggleLiveFullscreen()
            }
        case .grabFrame:
            controller.grabFrame()
        case .instantReplay:
            controller.instantReplay()
        case .addMarker:
            controller.addMarker()
        }
    }
}
