import AppKit
import SwiftUI
import Testing

@testable import TakeShotKit

/// The menu bar cannot be measured the way a view can — an NSMenu is built by
/// AppKit at click time. What CAN regress silently is what goes into it: a title
/// looked up with a key that does not exist (the menu then reads
/// "menu_play_pause"), and the shortcut rule that keeps a bare letter out of the
/// menu bar.
@MainActor
struct ModelAppCommandsTests {
    /// Every string the menu bar puts on screen, in the order the menus use it.
    /// A key with a typo renders as itself, which no build or lint step notices.
    private static let menuKeys = [
        "menu_playback", "menu_change_folder", "menu_play_pause",
        "menu_step_back", "menu_step_forward", "menu_skip_back",
        "menu_skip_forward", "menu_in_point", "menu_out_point", "menu_rating",
        "menu_scopes_overlay", "menu_scopes_window", "menu_lut", "menu_assists",
        "menu_fullscreen_player", "menu_vanc", "menu_help",
        // reused from elsewhere in the UI, because the menu item and the button
        // are the same action and should read the same
        "record", "stop", "grab_frame", "open_folder", "open_settings",
        "export_edl", "export_report_pdf", "export_report_csv", "offload_menu",
        "markers_title", "hotkey_marker", "hotkey_marker_delete",
        "marker_prev_help", "marker_next_help", "markers_clear_all",
        "good_take", "bad_take", "clear_rating", "playback_loop",
        "hotkey_replay", "lut_none", "lut_preview", "lut_record", "lut_import",
        "assist_tool", "assist_off", "assist_false_color", "assist_el_zone",
        "assist_zebra", "assist_peaking", "safe_areas", "punch_in",
    ]

    @Test func everyMenuTitleResolvesInBothLanguages() {
        for language in [AppLanguage.english, .russian] {
            ViewRender.withLanguage(language) {
                for key in Self.menuKeys {
                    #expect(L(key) != key,
                            "\(key) renders as its raw key in \(language.rawValue)")
                }
            }
        }
    }

    /// Menu titles end up in a menu bar that also has to fit the app menu and
    /// Window: a paragraph of help text pasted in as a title is a mistake this
    /// catches before the bar starts scrolling.
    @Test func menuTitlesAreTitlesNotSentences() {
        for language in [AppLanguage.english, .russian] {
            ViewRender.withLanguage(language) {
                for key in Self.menuKeys {
                    #expect(L(key).count <= 40,
                            "\(key) is \(L(key).count) characters long")
                }
            }
        }
    }

    /// A binding with ⌘ or ⌃ becomes a real key equivalent, so the menu shows
    /// the shortcut the operator actually has.
    @Test func modifierBindingsBecomeMenuShortcuts() {
        let record = HotkeyAction.toggleRecord.defaultCombo.menuShortcut
        #expect(record?.key.character == "r")
        #expect(record?.modifiers == .command)

        let control = KeyCombo(key: "k",
                               modifiers: NSEvent.ModifierFlags([.control, .shift])
                                   .rawValue,
                               keyCode: 40).menuShortcut
        #expect(control?.key.character == "k")
        #expect(control?.modifiers == [.control, .shift])
    }

    /// AppKit offers the main menu a key BEFORE the first responder sees it, so
    /// a bare "M" in the menu would drop a marker while the operator is typing a
    /// roll name. Those bindings stay with the local key monitor.
    @Test func bareLetterBindingsStayOutOfTheMenu() {
        for action in [HotkeyAction.addMarker, .removeMarker, .fullscreen,
                       .punchIn] {
            #expect(action.defaultCombo.menuShortcut == nil,
                    "\(action.rawValue) put an unmodified key in the menu bar")
        }
    }

    /// The scopes overlay and the preview LUT are reachable from the View menu
    /// AND from a key, and the menu item takes its shortcut from the binding
    /// (`hotkeys.combo(for:).menuShortcut`) rather than repeating it. Their
    /// defaults carry ⌃ precisely so the menu can show what the key is; a bare
    /// letter there would leave the menu silent about it.
    @Test func theMenuBackedTogglesShowTheirBinding() {
        for action in [HotkeyAction.toggleScopesOverlay, .toggleLUTPreview] {
            let shortcut = action.defaultCombo.menuShortcut
            #expect(shortcut != nil,
                    "\(action.rawValue) has a menu item but no menu shortcut")
            #expect(shortcut?.modifiers == .control)
        }
        #expect(HotkeyAction.toggleScopesOverlay.defaultCombo
            .menuShortcut?.key.character == "s")
        #expect(HotkeyAction.toggleLUTPreview.defaultCombo
            .menuShortcut?.key.character == "l")
    }

    @Test func namedKeysMapToTheirEquivalents() {
        let command = NSEvent.ModifierFlags.command.rawValue
        #expect(KeyCombo(key: "space", modifiers: command, keyCode: 49)
                    .menuShortcut?.key == .space)
        #expect(KeyCombo(key: "return", modifiers: command, keyCode: 36)
                    .menuShortcut?.key == .return)
        #expect(KeyCombo(key: "escape", modifiers: command, keyCode: 53)
                    .menuShortcut?.key == .escape)
    }
}
