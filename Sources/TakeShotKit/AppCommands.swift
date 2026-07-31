import AppKit
import CaptureCore
import SwiftUI

/// The menu bar.
///
/// What was there before was SwiftUI's default File/Edit/View — "New Window",
/// "Show Toolbar" and a Help item that opened nothing — in an app whose every
/// action lived in the window. These groups replace the boilerplate with the
/// real ones, and each item calls exactly the controller method the on-screen
/// button calls: the menu is a second way to reach an action, never a second
/// implementation of it.
///
/// Placement is by group rather than by inventing menus: `.newItem` is the top
/// of File, `.toolbar` is the View menu, `.appSettings` sits under About, and
/// `.help` is the Help menu. Edit is deliberately left alone — Undo, Cut, Copy
/// and Paste are what the naming fields in the footer are typed with, and
/// nothing about them is boilerplate.
struct TakeShotCommands: Commands {
    @ObservedObject var controller: CaptureController
    @ObservedObject var hotkeys: HotkeyManager

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            SettingsCommands()
        }
        CommandGroup(replacing: .newItem) {
            FileCommands(controller: controller, hotkeys: hotkeys)
        }
        CommandGroup(replacing: .toolbar) {
            ViewCommands(controller: controller, hotkeys: hotkeys)
        }
        CommandMenu(L("menu_playback")) {
            PlaybackCommands(controller: controller, hotkeys: hotkeys)
        }
        CommandGroup(replacing: .help) {
            HelpCommands()
        }
    }
}

// MARK: - the app menu

/// Settings has a window of its own rather than a `Settings` scene, so nothing
/// put the standard ⌘, item in the app menu.
private struct SettingsCommands: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(L("open_settings")) { openWindow(id: "settings") }
            .keyboardShortcut(",", modifiers: .command)
    }
}

// MARK: - File

private struct FileCommands: View {
    @ObservedObject var controller: CaptureController
    @ObservedObject var hotkeys: HotkeyManager

    var body: some View {
        Button(controller.isRecording ? L("stop") : L("record")) {
            controller.toggleManualRecord()
        }
        .keyboardShortcut(hotkeys.combo(for: .toggleRecord).menuShortcut)
        .disabled(!controller.isCapturing)

        Button(L("grab_frame")) { controller.grabFrame() }
            .keyboardShortcut(hotkeys.combo(for: .grabFrame).menuShortcut)
            .disabled(!controller.isCapturing && controller.playbackURL == nil)

        Divider()

        Button(L("open_folder")) { controller.openDestinationInFinder() }
            .keyboardShortcut("o", modifiers: [.command, .shift])
        Button(L("menu_change_folder")) { controller.chooseDestinationFolder() }

        Divider()

        ExportCommands(controller: controller)

        Divider()

        Button(L("offload_menu")) { controller.showOffloadSheet() }
        Button(L("verify_menu")) { controller.chooseDiskToVerify() }
    }
}

/// The same three exports the takes panel's share menu offers.
private struct ExportCommands: View {
    @ObservedObject var controller: CaptureController

    var body: some View {
        Button(L("export_edl")) { controller.exportSelectsEDL() }
            .disabled(!controller.takes.contains { $0.rating == .good })
        Button(L("export_report_pdf")) { controller.exportShiftReport(pdf: true) }
            .disabled(controller.takes.isEmpty)
        Button(L("export_report_csv")) { controller.exportShiftReport(pdf: false) }
            .disabled(controller.takes.isEmpty)
    }
}

// MARK: - Playback

private struct PlaybackCommands: View {
    @ObservedObject var controller: CaptureController
    @ObservedObject var hotkeys: HotkeyManager

    var body: some View {
        TransportCommands(controller: controller)

        Divider()

        LoopCommands(controller: controller)

        Divider()

        Menu(L("markers_title")) {
            MarkerCommands(controller: controller, hotkeys: hotkeys)
        }
        .disabled(!controller.isReviewingClip && !controller.isRecording)

        Menu(L("menu_rating")) {
            RatingCommands(controller: controller, hotkeys: hotkeys)
        }
        .disabled(controller.takes.isEmpty)

        Divider()

        Button(L("hotkey_replay")) { controller.instantReplay() }
            .keyboardShortcut(hotkeys.combo(for: .instantReplay).menuShortcut)
            .disabled(controller.takes.isEmpty)
    }
}

/// Nothing here means anything without a clip in the player, so every item is
/// disabled explicitly rather than relying on the group's environment: a
/// transport item that looks live and does nothing is worse than a grey one.
private struct TransportCommands: View {
    @ObservedObject var controller: CaptureController

    private var idle: Bool { !controller.isReviewingClip }

    var body: some View {
        Button(L("menu_play_pause")) { controller.togglePlayPause() }
            .disabled(idle)
        Button(L("menu_step_back")) { controller.stepPlayback(forward: false) }
            .disabled(idle)
        Button(L("menu_step_forward")) { controller.stepPlayback(forward: true) }
            .disabled(idle)
        Button(L("menu_skip_back")) { controller.skipPlayback(bySeconds: -5) }
            .disabled(idle)
        Button(L("menu_skip_forward")) { controller.skipPlayback(bySeconds: 5) }
            .disabled(idle)
    }
}

private struct LoopCommands: View {
    @ObservedObject var controller: CaptureController

    private var idle: Bool { !controller.isReviewingClip }

    var body: some View {
        Button(L("menu_in_point")) { controller.toggleLoopPoint(out: false) }
            .disabled(idle)
        Button(L("menu_out_point")) { controller.toggleLoopPoint(out: true) }
            .disabled(idle)
        Toggle(L("playback_loop"), isOn: Binding(
            get: { controller.loopPlayback },
            set: { controller.loopPlayback = $0 }))
            .disabled(idle)
    }
}

private struct MarkerCommands: View {
    @ObservedObject var controller: CaptureController
    @ObservedObject var hotkeys: HotkeyManager

    var body: some View {
        Button(L("hotkey_marker")) { controller.addMarker() }
            .keyboardShortcut(hotkeys.combo(for: .addMarker).menuShortcut)
        Button(L("hotkey_marker_delete")) { controller.removeNearestMarker() }
            .keyboardShortcut(hotkeys.combo(for: .removeMarker).menuShortcut)

        Divider()

        Button(L("marker_prev_help")) { controller.jumpToMarker(forward: false) }
            .disabled(controller.playbackMarkers.isEmpty)
        Button(L("marker_next_help")) { controller.jumpToMarker(forward: true) }
            .disabled(controller.playbackMarkers.isEmpty)
        Button(L("markers_clear_all")) { controller.clearPlaybackMarkers() }
            .disabled(controller.playbackMarkers.isEmpty)
    }
}

/// The rating of the LAST take — the same toggle the hotkeys drive, because
/// that is the take the operator has just watched go by.
private struct RatingCommands: View {
    @ObservedObject var controller: CaptureController
    @ObservedObject var hotkeys: HotkeyManager

    var body: some View {
        Button(L("good_take")) { controller.toggleLastRating(.good) }
            .keyboardShortcut(hotkeys.combo(for: .circleLastTake).menuShortcut)
        Button(L("bad_take")) { controller.toggleLastRating(.bad) }
            .keyboardShortcut(hotkeys.combo(for: .badTakeLast).menuShortcut)
        Button(L("clear_rating")) {
            guard let last = controller.takes.last else { return }
            controller.setRating(.none, for: last)
        }
    }
}

// MARK: - View

private struct ViewCommands: View {
    @ObservedObject var controller: CaptureController
    @ObservedObject var hotkeys: HotkeyManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Toggle(L("menu_scopes_overlay"), isOn: Binding(
            get: { controller.showScopesOverlay },
            set: { controller.showScopesOverlay = $0 }))
            .keyboardShortcut(hotkeys.combo(for: .toggleScopesOverlay).menuShortcut)
        Button(L("menu_scopes_window")) {
            openWindow(id: "scopes")
            // the overlay and the window show the same scopes; two at once is
            // twice the analysis for one pair of eyes
            controller.showScopesOverlay = false
        }

        Divider()

        Menu(L("menu_lut")) { LUTCommands(controller: controller, hotkeys: hotkeys) }
        Menu(L("menu_assists")) { AssistCommands(controller: controller) }

        Divider()

        Button(L("menu_fullscreen_player")) { controller.toggleViewerFullscreen() }
            .keyboardShortcut(hotkeys.combo(for: .fullscreen).menuShortcut)

        Divider()

        Button(L("menu_vanc")) { openWindow(id: "vanc-monitor") }
    }
}

/// The LUT list from the badge popover, as a menu.
private struct LUTCommands: View {
    @ObservedObject var controller: CaptureController
    @ObservedObject var hotkeys: HotkeyManager

    var body: some View {
        Picker(L("menu_lut"), selection: Binding(
            get: { controller.settings.lutFileName },
            set: { controller.selectLUT(fileName: $0) })) {
            Text(L("lut_none")).tag(String?.none)
            ForEach(controller.availableLUTs) { lut in
                Text(lut.name).tag(String?.some(lut.fileName))
            }
        }
        .pickerStyle(.inline)

        Divider()

        Toggle(L("lut_preview"), isOn: Binding(
            get: { controller.lutPreviewOn },
            set: { controller.lutPreviewOn = $0 }))
            .keyboardShortcut(hotkeys.combo(for: .toggleLUTPreview).menuShortcut)
            .disabled(controller.settings.lutFileName == nil)
        Toggle(L("lut_record"), isOn: Binding(
            get: { controller.lutRecordOn },
            set: { controller.lutRecordOn = $0 }))
            .disabled(controller.settings.lutFileName == nil)

        Divider()

        Button(L("lut_import")) { controller.importLUT() }
    }
}

/// The operator aids that are a plain on/off — the ones with a threshold or a
/// ratio stay in the popover, where they have their slider.
private struct AssistCommands: View {
    @ObservedObject var controller: CaptureController

    var body: some View {
        ColorToolPicker(selection: Binding(
            get: { controller.assist.colorTool },
            set: { controller.assist.colorTool = $0 }))
            .pickerStyle(.inline)

        Divider()

        Toggle(L("assist_zebra"), isOn: Binding(
            get: { controller.assist.zebraOn },
            set: { controller.assist.zebraOn = $0 }))
        Toggle(L("assist_peaking"), isOn: Binding(
            get: { controller.assist.peakingOn },
            set: { controller.assist.peakingOn = $0 }))
        Toggle(L("safe_areas"), isOn: Binding(
            get: { controller.settings.safeAreasOn ?? false },
            set: { controller.settings.safeAreasOn = $0 }))
        Toggle(L("punch_in"), isOn: Binding(
            get: { controller.assist.punchIn > 1 },
            set: { _ in controller.togglePunchIn() }))
    }
}

// MARK: - Help

private struct HelpCommands: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(L("menu_help")) { openWindow(id: "help") }
            .keyboardShortcut("?", modifiers: .command)
    }
}

// MARK: - shortcuts

extension KeyCombo {
    /// The binding as a menu shortcut — nil unless it carries ⌘ or ⌃.
    ///
    /// A bare letter is a legal key equivalent and a dangerous one: AppKit
    /// offers the main menu a key BEFORE the first responder sees it, so "M" in
    /// a menu would drop a marker while the operator is typing a roll name in
    /// the footer. Those bindings stay with the local key monitor, which lets
    /// typing through on purpose; the help page and Settings list them.
    var menuShortcut: KeyboardShortcut? {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        guard flags.contains(.command) || flags.contains(.control),
              let equivalent = keyEquivalent else { return nil }
        var eventModifiers: EventModifiers = []
        if flags.contains(.command) { eventModifiers.insert(.command) }
        if flags.contains(.control) { eventModifiers.insert(.control) }
        if flags.contains(.option) { eventModifiers.insert(.option) }
        if flags.contains(.shift) { eventModifiers.insert(.shift) }
        return KeyboardShortcut(equivalent, modifiers: eventModifiers)
    }

    private var keyEquivalent: KeyEquivalent? {
        switch key {
        case "space": return .space
        case "return": return .return
        case "escape": return .escape
        default:
            guard let character = key.first else { return nil }
            return KeyEquivalent(character)
        }
    }
}
