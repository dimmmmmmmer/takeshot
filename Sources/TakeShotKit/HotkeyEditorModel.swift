import Foundation
import SwiftUI

/// The keyboard-shortcut editor's model: which rows the list shows, and the two
/// ways back to a default.
///
/// The bindings themselves stay on `HotkeyManager` — it owns the storage, the
/// conflict rule and the key-recording monitor, and the editor must not become a
/// second place where a chord can be assigned. What lives here is everything the
/// editor adds on top: the filter over an action list that had grown long enough
/// to make the settings window scroll past it, and the localized name of
/// whatever refused a chord.
@MainActor
final class HotkeyEditorModel: ObservableObject {
    /// The search field's text. Matched against the action's localized title and
    /// against the chord as it is displayed, so "⌘R" and "record" both find the
    /// record row.
    @Published var query: String = ""

    private let hotkeys: HotkeyManager

    init(hotkeys: HotkeyManager) {
        self.hotkeys = hotkeys
    }

    /// The actions the list shows, in the order they are declared — a stable
    /// order the operator can learn, not one that reshuffles as bindings change.
    var rows: [HotkeyAction] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return HotkeyAction.allCases }
        return HotkeyAction.allCases.filter { matches($0, needle) }
    }

    /// Case- and diacritic-insensitive, because the Russian titles are typed by
    /// someone who may not bother with ё, and the chord glyphs are matched too.
    private func matches(_ action: HotkeyAction, _ needle: String) -> Bool {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let haystack = [L(action.titleKey), hotkeys.combo(for: action).display]
        return haystack.contains { $0.range(of: needle, options: options) != nil }
    }

    /// Nothing matched — the list is empty on purpose rather than broken, and
    /// the view says so.
    var isEmpty: Bool { rows.isEmpty }

    func combo(for action: HotkeyAction) -> KeyCombo { hotkeys.combo(for: action) }

    func isCustomized(_ action: HotkeyAction) -> Bool {
        hotkeys.isCustomized(action)
    }

    var isRecording: Bool { hotkeys.recordingAction != nil }

    func isRecording(_ action: HotkeyAction) -> Bool {
        hotkeys.recordingAction == action
    }

    /// Start capturing a chord for `action`, or stop if it was already the one
    /// capturing. Any previous refusal goes with it: the banner belongs to the
    /// attempt that caused it.
    func toggleRecording(_ action: HotkeyAction) {
        hotkeys.clearRefusal()
        hotkeys.recordingAction = isRecording(action) ? nil : action
    }

    func reset(_ action: HotkeyAction) {
        hotkeys.resetToDefault(action)
    }

    func resetAll() {
        hotkeys.resetToDefaults()
    }

    /// The refusal banner, already localized: which chord was refused and what
    /// holds it. nil when the last assignment went through.
    var refusalText: String? {
        guard let refusal = hotkeys.lastRefusal else { return nil }
        return L("hotkey_conflict", L(refusal.conflict.ownerTitleKey))
    }
}
