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
    /// Monitors an `install` found already up and took down first. The main
    /// window's `onAppear` runs again when the window is reopened, and a
    /// monitor never goes away by itself: the second install used to stack
    /// on the first, and every press then reached the app twice.
    private(set) var staleMonitorsRemoved = 0
    /// Whether a monitor is up at all — the premise a headless test has to
    /// state before it can say anything about two installs.
    var hasMonitor: Bool { monitor != nil }
    /// Injectable so tests get their own suite instead of the operator's
    /// bindings; production always uses the standard defaults.
    private let defaults: UserDefaults
    private static let defaultsKey = "TakeShot.Hotkeys"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = Self.storedBindings(in: defaults)
        var result: [HotkeyAction: KeyCombo] = [:]
        for action in HotkeyAction.allCases {
            result[action] = stored[action.rawValue] ?? action.defaultCombo
        }
        // grab-still default moved ⌘⇧S → ⌘S: migrate an untouched binding
        let oldGrabDefault = KeyCombo(
            key: "s", modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue,
            keyCode: 1)
        // …unless the operator had already put something of THEIR OWN on ⌘S:
        // a migration that moved a stored entry onto a stored chord made the
        // very collision the yield below exists to prevent
        if result[.grabFrame] == oldGrabDefault,
           !stored.contains(where: { $0.key != HotkeyAction.grabFrame.rawValue
               && $0.value.sharesKey(with: HotkeyAction.grabFrame.defaultCombo) }) {
            result[.grabFrame] = HotkeyAction.grabFrame.defaultCombo
        }
        bindings = Self.yieldingNewDefaults(result, storedFor: stored.keys)
    }

    /// One entry of the stored record, or nothing when that entry will not
    /// decode. The record used to be read as a whole, so one malformed chord
    /// — a hand edit, a field a later build added — put EVERY action back on
    /// its default, and the next re-bind saved the reset. Now only that
    /// entry's own action comes up on its default.
    private struct StoredCombo: Decodable {
        let combo: KeyCombo?
        init(from decoder: Decoder) throws { combo = try? KeyCombo(from: decoder) }
    }

    private static func storedBindings(in defaults: UserDefaults) -> [String: KeyCombo] {
        guard let data = defaults.data(forKey: defaultsKey),
              let stored = try? JSONDecoder().decode([String: StoredCombo].self,
                                                     from: data) else { return [:] }
        return stored.compactMapValues(\.combo)
    }

    /// An action the record predates arrives on today's default; when the
    /// operator had already put one of THEIR bindings on that chord, the
    /// newcomer yields and comes up unbound. The alternative was two actions
    /// on one key, fired in dictionary order — REC one day, dim the monitors
    /// the next — which is the bug `HotkeyConflict` exists to make impossible
    /// by hand and which an update could still create on its own.
    private static func yieldingNewDefaults(_ bindings: [HotkeyAction: KeyCombo],
                                            storedFor stored: Dictionary<String, KeyCombo>.Keys)
        -> [HotkeyAction: KeyCombo] {
        var result = bindings
        for action in HotkeyAction.allCases where !stored.contains(action.rawValue) {
            guard let combo = result[action] else { continue }
            let taken = HotkeyAction.allCases.contains { other in
                other != action && stored.contains(other.rawValue)
                    && (result[other]?.sharesKey(with: combo) ?? false)
            }
            if taken { result[action] = .unbound }
        }
        return result
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
    /// back at all. So the reset WINS and whoever was sitting on the chord
    /// comes off it — the alternative is two actions on one key, fired in
    /// dictionary order, which is the state `HotkeyConflict` exists to make
    /// unreachable. This is the way back from a yielded binding as well: the
    /// row shows "—", the arrow puts the default back, and the action that
    /// took the chord during the update is the one that gives it up.
    func resetToDefault(_ action: HotkeyAction) {
        let restored = action.defaultCombo
        for other in HotkeyAction.allCases
        where other != action && combo(for: other).sharesKey(with: restored) {
            set(.unbound, for: other)
        }
        set(restored, for: action)
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
            other != action && self.combo(for: other).sharesKey(with: combo)
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

    /// What one key press over a running app MEANS.
    ///
    /// A value rather than five branches inside the monitor, because the
    /// monitor itself cannot be driven from a test: a local `NSEvent` monitor
    /// wants a real application event queue, and a synthesized event cannot be
    /// routed into one. Stated over the facts a press carries, the rule is
    /// ordinary code — and it is worth pinning, because it decides whether the
    /// key under the operator's finger reaches the app or the scene name they
    /// are halfway through typing.
    ///
    /// The ORDER is the rule as much as the arms are. Esc leaves a fullscreen
    /// surface before it cancels a recording, on the grounds that the
    /// fullscreen is the bigger state and the only way out of it is this key.
    /// The consequence, stated rather than left to be discovered: a combo row
    /// armed in Settings while a fullscreen window is up stays armed until the
    /// operator presses Esc a second time.
    func outcome(for press: HotkeyPress,
                 isPlaybackFullscreen: Bool,
                 isLiveFullscreen: Bool) -> HotkeyOutcome {
        if press.isEscape {
            if isPlaybackFullscreen { return .leavePlaybackFullscreen }
            if isLiveFullscreen { return .leaveLiveFullscreen }
        }
        // a new combo is being recorded in settings: the row swallows the
        // press either way, so the operator is never stuck capturing keys
        if let recording = recordingAction {
            if press.isEscape { return .cancelRecording }
            guard let combo = press.combo else { return .keepRecording }
            return .bind(combo, to: recording)
        }
        if Self.typingKeepsTheKey(modifiers: press.modifiers,
                                  isTyping: press.isTyping) {
            return .passThrough
        }
        for (action, combo) in bindings where combo.matches(press) {
            return .perform(action)
        }
        return .passThrough
    }

    /// Intercept keys in all app windows (not system-global).
    ///
    /// Reads the facts off the event and applies the outcome; the RULE is
    /// `outcome`, which is a function of those facts alone.
    func install(controller: CaptureController) {
        controller.hotkeysRef = self
        if let monitor {
            NSEvent.removeMonitor(monitor)
            staleMonitorsRemoved += 1
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak controller] event in
            guard let self, let controller else { return event }
            let press = HotkeyPress(
                event: event,
                isTyping: event.window?.firstResponder is NSTextView)
            switch self.outcome(
                for: press,
                isPlaybackFullscreen: controller.isPlaybackFullscreen,
                isLiveFullscreen: controller.isLiveFullscreen) {
            case .passThrough:
                return event
            case .leavePlaybackFullscreen:
                controller.togglePlaybackFullscreen()
            case .leaveLiveFullscreen:
                controller.toggleLiveFullscreen()
            case .cancelRecording:
                self.recordingAction = nil
            case .keepRecording:
                break
            case .bind(let combo, let action):
                // refused chords leave the row where it was and put the
                // owner's name on screen; the recording stops either way
                self.assign(combo, to: action)
                self.recordingAction = nil
            case .perform(let action):
                self.perform(action, controller: controller)
            }
            return nil
        }
    }
}

/// What a key press carries that the hotkey rule needs, as a value.
///
/// A struct rather than four parameters, because that is what these are: one
/// reading off one `NSEvent`, plus the single fact about the WINDOW that no
/// event carries. It also lets a test state only what a case is about.
struct HotkeyPress {
    /// Escape. The one key the rule names outright, and it names it twice.
    static let escapeKeyCode: UInt16 = 53

    /// The physical key. Hotkeys are matched on it so a Cyrillic layout keeps
    /// working (see `KeyCombo.matches`).
    var keyCode: UInt16
    var modifiers: NSEvent.ModifierFlags = []
    /// The chord this press amounts to, or nil for a press nothing can be
    /// bound to — a bare modifier, or a key that produces no character.
    var combo: KeyCombo?
    /// A text field owns the keyboard. Not read off the event: it is a fact
    /// about the window, and the only one here a test cannot state.
    var isTyping = false

    var isEscape: Bool { keyCode == Self.escapeKeyCode }

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags = [],
         combo: KeyCombo? = nil, isTyping: Bool = false) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.combo = combo
        self.isTyping = isTyping
    }

    /// The whole of what the monitor does before the rule takes over.
    init(event: NSEvent, isTyping: Bool) {
        keyCode = event.keyCode
        modifiers = event.modifierFlags
        combo = KeyCombo.from(event: event)
        self.isTyping = isTyping
    }
}

/// What one key press amounts to.
enum HotkeyOutcome: Equatable {
    /// Not ours: hand the press on to whatever owns the keyboard.
    case passThrough
    /// Leave the playback fullscreen surface.
    case leavePlaybackFullscreen
    /// Leave the live fullscreen surface.
    case leaveLiveFullscreen
    /// Stop recording a combo, leaving the binding where it was.
    case cancelRecording
    /// Bind this chord to the row being recorded, and stop recording.
    case bind(KeyCombo, to: HotkeyAction)
    /// Swallowed, and the row stays armed: nothing can be bound to this press.
    case keepRecording
    /// Run this action.
    case perform(HotkeyAction)
}
