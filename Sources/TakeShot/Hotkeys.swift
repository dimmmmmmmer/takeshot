import AppKit
import Foundation

/// Комбинация клавиш: символ + модификаторы.
struct KeyCombo: Codable, Equatable {
    var key: String        // символ в нижнем регистре ("r") или спец-имя ("space", "return")
    var modifiers: UInt    // NSEvent.ModifierFlags.rawValue (deviceIndependent)

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
        return KeyCombo(key: key, modifiers: flags.rawValue)
    }

    func matches(event: NSEvent) -> Bool {
        Self.from(event: event) == self
    }
}

/// Действия, на которые вешаются хоткеи.
enum HotkeyAction: String, CaseIterable, Codable, Identifiable {
    case toggleRecord
    case circleLastTake

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .toggleRecord: return "hotkey_record"
        case .circleLastTake: return "hotkey_circle"
        }
    }

    var defaultCombo: KeyCombo {
        switch self {
        case .toggleRecord:
            return KeyCombo(key: "r", modifiers: NSEvent.ModifierFlags.command.rawValue)
        case .circleLastTake:
            return KeyCombo(key: "g", modifiers: NSEvent.ModifierFlags.command.rawValue)
        }
    }
}

/// Хранение биндингов и локальный перехват клавиш в приложении.
@MainActor
final class HotkeyManager: ObservableObject {
    @Published private(set) var bindings: [HotkeyAction: KeyCombo]
    /// Действие, для которого сейчас записывается новая комбинация (UI-состояние).
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

    /// Перехват клавиш во всех окнах приложения (не системно-глобальный).
    func install(controller: CaptureController) {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak controller] event in
            guard let self, let controller else { return event }

            // идёт запись новой комбинации в настройках
            if let recording = self.recordingAction {
                if event.keyCode == 53 { // Esc — отмена
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

            // не перехватываем ввод в текстовых полях, если комбинация без ⌘/⌃
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
            controller.circleLastTake()
        }
    }
}
