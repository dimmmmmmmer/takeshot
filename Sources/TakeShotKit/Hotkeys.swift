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
    case removeMarker
    case punchIn
    // The viewer and monitoring toggles. Every one of them already had a
    // button or a menu item; what they did not have was a key, and each is
    // something the operator reaches for with one hand while looking at the
    // picture rather than at the window.
    case toggleScopesOverlay
    case toggleLUTPreview
    case toggleMonitorMute
    case toggleMonitorDim
    case toggleViewerMode
    case toggleAudioChannelBank

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
        case .removeMarker: return "hotkey_marker_delete"
        case .punchIn: return "hotkey_punch_in"
        case .toggleScopesOverlay: return "hotkey_scopes_overlay"
        case .toggleLUTPreview: return "hotkey_lut_preview"
        case .toggleMonitorMute: return "hotkey_monitor_mute"
        case .toggleMonitorDim: return "hotkey_monitor_dim"
        case .toggleViewerMode: return "hotkey_viewer_mode"
        case .toggleAudioChannelBank: return "hotkey_audio_bank"
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
            // ⌘S — grab still
            return KeyCombo(key: "s", modifiers: NSEvent.ModifierFlags.command.rawValue,
                            keyCode: 1)
        case .instantReplay:
            // ⌘E — replay the last take
            return KeyCombo(key: "e", modifiers: NSEvent.ModifierFlags.command.rawValue,
                            keyCode: 14)
        case .addMarker:
            // M — flag the moment (NLE convention)
            return KeyCombo(key: "m", modifiers: 0, keyCode: 46)
        case .removeMarker:
            // ⇧M — remove the marker under the playhead (last one while recording)
            return KeyCombo(key: "m", modifiers: NSEvent.ModifierFlags.shift.rawValue,
                            keyCode: 46)
        case .punchIn:
            // Z — 2x center magnification (focus check)
            return KeyCombo(key: "z", modifiers: 0, keyCode: 6)

        // The viewer and monitoring toggles are one family on ⌃ + a mnemonic
        // letter, for three reasons that point the same way: ⌘ + letter is
        // largely spoken for (AppKit keeps ⌘W/⌘M/⌘H/⌘Q, Edit owns ⌘Z/X/C/V/A,
        // and this app already took ⌘R/G/B/S/E); a binding reaches the menu bar
        // only if it carries ⌘ or ⌃ (see `menuShortcut`), and two of the six sit
        // on menu items that should show their key; and one modifier for one
        // group is learned in a batch, where six unrelated bare letters is a
        // list to memorize. ⌃M for mute is deliberately NOT among them — M is
        // the marker key here, and a third meaning on it is how the wrong thing
        // gets pressed in a hurry.
        case .toggleScopesOverlay:
            // ⌃S — Scopes (⌘S is the still)
            return KeyCombo(key: "s",
                            modifiers: NSEvent.ModifierFlags.control.rawValue,
                            keyCode: 1)
        case .toggleLUTPreview:
            // ⌃L — the LUT on the preview
            return KeyCombo(key: "l",
                            modifiers: NSEvent.ModifierFlags.control.rawValue,
                            keyCode: 37)
        case .toggleMonitorMute:
            // ⌃A — Audio, since M belongs to the markers
            return KeyCombo(key: "a",
                            modifiers: NSEvent.ModifierFlags.control.rawValue,
                            keyCode: 0)
        case .toggleMonitorDim:
            // ⌃D — DIM, as the footer button is labelled
            return KeyCombo(key: "d",
                            modifiers: NSEvent.ModifierFlags.control.rawValue,
                            keyCode: 2)
        case .toggleViewerMode:
            // ⌃V — the Viewer's rec/playback switch
            return KeyCombo(key: "v",
                            modifiers: NSEvent.ModifierFlags.control.rawValue,
                            keyCode: 9)
        case .toggleAudioChannelBank:
            // ⌃I — the sound department's ISO tracks
            return KeyCombo(key: "i",
                            modifiers: NSEvent.ModifierFlags.control.rawValue,
                            keyCode: 34)
        }
    }
}
