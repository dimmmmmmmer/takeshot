import AppKit
import Foundation

/// A key combo: a symbol + modifiers.
struct KeyCombo: Codable, Equatable {
    var key: String        // symbol for display ("r", "space", "return")
    var modifiers: UInt    // NSEvent.ModifierFlags.rawValue (deviceIndependent)
    /// Physical key: we match on it so hotkeys work on any keyboard layout.
    var keyCode: UInt16?

    var display: String {
        // an action that yielded its chord shows a dash, not a blank button
        if isUnbound { return "—" }
        var parts = ""
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        if flags.contains(.control) { parts += "⌃" }
        if flags.contains(.option) { parts += "⌥" }
        if flags.contains(.shift) { parts += "⇧" }
        if flags.contains(.command) { parts += "⌘" }
        let names = ["space": "Space", "return": "↩", "escape": "⎋",
                     "left": "←", "right": "→", "up": "↑", "down": "↓"]
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
        // **The arrows, by keyCode.** Their
        // `charactersIgnoringModifiers` is a private-use glyph
        // (U+F702 and friends) that no font an operator has draws
        // and no `uppercased()` improves, so a binding stored that
        // way reads as a blank box in the editor.
        case 123: key = "left"
        case 124: key = "right"
        case 125: key = "down"
        case 126: key = "up"
        default:
            guard let chars = event.charactersIgnoringModifiers?.lowercased(),
                  let first = chars.first, !first.isWhitespace else { return nil }
            key = String(first)
        }
        return KeyCombo(key: key, modifiers: flags.rawValue, keyCode: event.keyCode)
    }

    /// Whether this binding answers to `press`.
    ///
    /// Stated over the press rather than over an `NSEvent` so the hotkey rule
    /// can ask it without one (see `HotkeyManager.outcome`) — and so the
    /// modifier mask is spelled once instead of once here and once in
    /// `from(event:)`.
    /// Whether two bindings answer to the same press: the physical key when
    /// both know it, the symbol when one is a legacy record without one. The
    /// conflict check used to compare symbols only while `matches` fires on
    /// the physical key — so ⌘ы and ⌘s (both keyCode 1 under a Russian
    /// layout) passed the check and then collided on the key.
    func sharesKey(with other: KeyCombo) -> Bool {
        guard !isUnbound, !other.isUnbound, modifiers == other.modifiers else { return false }
        if let keyCode, let otherCode = other.keyCode { return keyCode == otherCode }
        return key == other.key
    }

    /// No chord at all — what an action is left on when the chord it ships
    /// with was already the operator's binding for something else.
    static let unbound = KeyCombo(key: "", modifiers: 0, keyCode: nil)
    var isUnbound: Bool { key.isEmpty && keyCode == nil }

    func matches(_ press: HotkeyPress) -> Bool {
        guard !isUnbound else { return false }
        let flags = press.modifiers
            .intersection(.deviceIndependentFlagsMask)
            .intersection([.command, .option, .control, .shift])
        guard flags.rawValue == modifiers else { return false }
        if let keyCode {
            // by physical key — the keyboard layout doesn't matter (same key in Latin/Cyrillic)
            return press.keyCode == keyCode
        }
        // old saved combos without a keyCode — by symbol
        return press.combo?.key == key
    }

    func matches(event: NSEvent) -> Bool {
        matches(HotkeyPress(event: event, isTyping: false))
    }
}

/// A chord the app answers to that is NOT remappable: a fixed key equivalent on
/// a menu item or a view.
///
/// Production data rather than a list in a test, because two things need it and
/// they must not drift apart: the editor, which refuses to bind a chord AppKit
/// has already spoken for, and the test that checks no shipped default lands on
/// one. `key` and `modifiers` are what AppKit actually matches a key equivalent
/// on — the same two fields `KeyCombo` compares.
struct ReservedShortcut {
    let key: String
    let modifiers: UInt
    /// Localization key naming what owns the chord, for the conflict message.
    let titleKey: String
    /// The physical key, which is what the monitor fires on and what the
    /// chord is compared by. `key` is the symbol of whatever layout the
    /// operator was in when they recorded their chord: ⌘в on a Russian
    /// layout is the ⌘V key, and a symbol comparison let paste be bound over.
    let keyCode: UInt16?

    func matches(_ combo: KeyCombo) -> Bool {
        KeyCombo(key: key, modifiers: modifiers, keyCode: keyCode)
            .sharesKey(with: combo)
    }

    /// Every fixed shortcut in the app. Keep in step with the `keyboardShortcut`
    /// modifiers in `AppCommands`, `TakeRowControls`, the transport bars and the
    /// overlay dismissals.
    static let all: [ReservedShortcut] = {
        let command = NSEvent.ModifierFlags.command.rawValue
        let commandShift = NSEvent.ModifierFlags([.command, .shift]).rawValue
        return [
            ReservedShortcut(key: ",", modifiers: command,
                             titleKey: "reserved_settings", keyCode: 43),
            ReservedShortcut(key: "o", modifiers: commandShift,
                             titleKey: "reserved_open_folder", keyCode: 31),
            ReservedShortcut(key: "?", modifiers: command,
                             titleKey: "reserved_help", keyCode: 44),
            // The Edit menu's and AppKit's own. ⌘ chords reach the hotkeys
            // even while a field has the keyboard (`typingKeepsTheKey`), so
            // a binding on ⌘V would take paste from every text field, and one
            // on ⌘Q would quit — or be refused by the system, unpredictably.
            ReservedShortcut(key: "c", modifiers: command,
                             titleKey: "reserved_edit_menu", keyCode: 8),
            ReservedShortcut(key: "v", modifiers: command,
                             titleKey: "reserved_edit_menu", keyCode: 9),
            ReservedShortcut(key: "x", modifiers: command,
                             titleKey: "reserved_edit_menu", keyCode: 7),
            ReservedShortcut(key: "a", modifiers: command,
                             titleKey: "reserved_edit_menu", keyCode: 0),
            ReservedShortcut(key: "z", modifiers: command,
                             titleKey: "reserved_edit_menu", keyCode: 6),
            ReservedShortcut(key: "q", modifiers: command,
                             titleKey: "reserved_app_menu", keyCode: 12),
            ReservedShortcut(key: "w", modifiers: command,
                             titleKey: "reserved_app_menu", keyCode: 13),
            ReservedShortcut(key: "h", modifiers: command,
                             titleKey: "reserved_app_menu", keyCode: 4),
            ReservedShortcut(key: "m", modifiers: command,
                             titleKey: "reserved_app_menu", keyCode: 46),
            ReservedShortcut(key: "space", modifiers: 0,
                             titleKey: "reserved_play_pause", keyCode: 49),
            ReservedShortcut(key: "escape", modifiers: 0,
                             titleKey: "reserved_close_overlay", keyCode: 53),
        ]
    }()

    static func owning(_ combo: KeyCombo) -> ReservedShortcut? {
        all.first { $0.matches(combo) }
    }
}

/// What already answers to a chord the operator just pressed.
///
/// `install` walks the bindings dictionary and fires the FIRST action whose
/// combo matches; dictionary order is not defined, so a chord on two actions
/// fires unpredictably — REC one day, grab-still the next. That is the bug this
/// type exists to make impossible to create by hand.
enum HotkeyConflict: Equatable {
    /// Another remappable action holds it.
    case action(HotkeyAction)
    /// A fixed shortcut holds it, named by its localization key.
    case reserved(String)

    /// The localization key naming the owner.
    var ownerTitleKey: String {
        switch self {
        case .action(let action): return action.titleKey
        case .reserved(let key): return key
        }
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
    case toggleCleanFeed
    // **The transport, the way an editor's hands already know it** (owner:
    // "как в давинчи для транспорта по плейбеку хочу клавиши J K L и
    // стрелочками влево вправо чтобы по фрейму можно было двигаться, а через
    // шифт и стрелочки на 5 фреймов к примеру, а стрелки вверх вниз к началу
    // или к концу тейка меня двигали").
    //
    // Bare keys, unlike the ⌃ family above, and that is the point of them: a
    // transport is worked with one hand while the other is on the mouse, and
    // J-K-L with a modifier is not J-K-L. They are editable like everything
    // else here — a Russian layout puts О-Л-Д under those fingers, and the
    // binding follows the physical key (`sharesKey`).
    case resetAssists
    case toggleAssistsHidden
    case shuttleReverse
    case shuttleStop
    case shuttleForward
    case stepBackOneFrame
    case stepForwardOneFrame
    case stepBackFiveFrames
    case stepForwardFiveFrames
    case goToClipStart
    case goToClipEnd

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
        case .toggleCleanFeed: return "hotkey_clean_feed"
        case .resetAssists: return "hotkey_assists_reset"
        case .toggleAssistsHidden: return "hotkey_assists_hidden"
        case .shuttleReverse: return "hotkey_shuttle_reverse"
        case .shuttleStop: return "hotkey_shuttle_stop"
        case .shuttleForward: return "hotkey_shuttle_forward"
        case .stepBackOneFrame: return "hotkey_step_back"
        case .stepForwardOneFrame: return "hotkey_step_forward"
        case .stepBackFiveFrames: return "hotkey_step_back_five"
        case .stepForwardFiveFrames: return "hotkey_step_forward_five"
        case .goToClipStart: return "hotkey_clip_start"
        case .goToClipEnd: return "hotkey_clip_end"
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
        case .toggleCleanFeed:
            // ⌃U — the UI, off and on. The one key in this family an operator
            // presses while somebody is standing behind them looking at the
            // picture, so it has to be reachable without looking.
            return KeyCombo(key: "u",
                            modifiers: NSEvent.ModifierFlags.control.rawValue,
                            keyCode: 32)

        case .resetAssists:
            // ⌃0 — zero the aids. Not ⌃R: R is the record key one modifier
            // away, and "reset" is not a word to put next to it in a hurry.
            return KeyCombo(key: "0",
                            modifiers: NSEvent.ModifierFlags.control.rawValue,
                            keyCode: 29)
        case .toggleAssistsHidden:
            // ⌃H — Hide them, and bring them back. It joins the ⌃ family for
            // the reason stated there, and sits beside ⌃U: one takes the app's
            // chrome off the picture, the other the operator's marks.
            return KeyCombo(key: "h",
                            modifiers: NSEvent.ModifierFlags.control.rawValue,
                            keyCode: 4)

        // J-K-L and the arrows, bare — see the enum case for why.
        case .shuttleReverse:
            return KeyCombo(key: "j", modifiers: 0, keyCode: 38)
        case .shuttleStop:
            return KeyCombo(key: "k", modifiers: 0, keyCode: 40)
        case .shuttleForward:
            return KeyCombo(key: "l", modifiers: 0, keyCode: 37)
        case .stepBackOneFrame:
            return KeyCombo(key: "left", modifiers: 0, keyCode: 123)
        case .stepForwardOneFrame:
            return KeyCombo(key: "right", modifiers: 0, keyCode: 124)
        case .stepBackFiveFrames:
            return KeyCombo(key: "left",
                            modifiers: NSEvent.ModifierFlags.shift.rawValue,
                            keyCode: 123)
        case .stepForwardFiveFrames:
            return KeyCombo(key: "right",
                            modifiers: NSEvent.ModifierFlags.shift.rawValue,
                            keyCode: 124)
        case .goToClipStart:
            return KeyCombo(key: "up", modifiers: 0, keyCode: 126)
        case .goToClipEnd:
            return KeyCombo(key: "down", modifiers: 0, keyCode: 125)
        }
    }
}
