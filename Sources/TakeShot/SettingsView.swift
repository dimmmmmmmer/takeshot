import CaptureCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var controller: CaptureController
    @EnvironmentObject private var hotkeys: HotkeyManager
    @State private var confirmClearLUTs = false

    /// Vendor naming presets (see NamingPreset.all; kept as an alias so both
    /// Settings and the footer menu read the same list).
    static let namingPresets = NamingPreset.all

    var body: some View {
        Form {
            Section(L("settings_device")) {
                Picker(L("device"), selection: $controller.selectedDeviceID) {
                    if controller.devices.isEmpty {
                        Text(L("no_devices")).tag(String?.none)
                    }
                    ForEach(controller.devices) { device in
                        Text(device.name).tag(String?.some(device.id))
                    }
                }
                .disabled(controller.isRecording)
            }
            Section(L("settings_interface")) {
                Picker(L("language"), selection: Binding(
                    get: { controller.appLanguage },
                    set: { controller.appLanguage = $0 })) {
                    Text(L("lang_english")).tag(AppLanguage.english)
                    Text(L("lang_russian")).tag(AppLanguage.russian)
                    Text(L("lang_system")).tag(AppLanguage.system)
                }
                Picker(L("theme"), selection: Binding(
                    get: { controller.settings.appearance ?? "system" },
                    set: { controller.settings.appearance = $0 == "system" ? nil : $0 })) {
                    Text(L("theme_system")).tag("system")
                    Text(L("theme_light")).tag("light")
                    Text(L("theme_dark")).tag("dark")
                }
                ColorPicker(L("player_background"), selection: Binding(
                    get: { controller.playerBackground },
                    set: { controller.playerBackground = $0 }),
                    supportsOpacity: false)
                ColorPicker(L("app_background"), selection: Binding(
                    get: { controller.appBackground },
                    set: { controller.appBackground = $0 }),
                    supportsOpacity: false)
                ColorPicker(L("accent_color"), selection: Binding(
                    get: { controller.accentColor },
                    set: { controller.accentColor = $0 }),
                    supportsOpacity: false)
                Picker(L("panel_position"), selection: $controller.panelSide) {
                    Text(L("panel_right")).tag("right")
                    Text(L("panel_left")).tag("left")
                }
                Button(L("reset_colors"), role: .destructive) {
                    controller.resetColors()
                }
            }
            Section(L("settings_recording")) {
                Picker(L("codec"), selection: $controller.settings.codec) {
                    ForEach(CaptureCodec.allCases) { codec in
                        Text(codec.rawValue).tag(codec)
                    }
                }
                TextField(L("project"), text: $controller.settings.projectName)
                LabeledContent(L("destination_folder")) {
                    HStack {
                        Text(controller.settings.destinationPath)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button(L("choose_folder")) {
                            controller.chooseDestinationFolder()
                        }
                    }
                }
                Picker(L("naming_preset"), selection: Binding(
                    get: {
                        Self.namingPresets.first {
                            $0.template == controller.settings.namingTemplate
                        }?.key ?? "preset_custom"
                    },
                    set: { key in
                        if let preset = Self.namingPresets.first(where: { $0.key == key }) {
                            controller.applyNamingPreset(preset)
                        }
                    })) {
                    ForEach(Self.namingPresets, id: \.key) { preset in
                        Text(L(preset.key)).tag(preset.key)
                    }
                    Text(L("preset_custom")).tag("preset_custom")
                }
                TextField(L("naming_template"), text: $controller.settings.namingTemplate)
                Text(L("placeholders_legend"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Picker(L("color_tags"), selection: Binding(
                    get: { controller.settings.colorTagPreset ?? "709" },
                    set: { controller.settings.colorTagPreset = $0 == "709" ? nil : $0 })) {
                    Text("Rec.709 (1-1-1)").tag("709")
                    Text("Rec.601").tag("601")
                    Text("Rec.2020").tag("2020")
                }
                Picker(L("video_levels"), selection: Binding(
                    get: { controller.settings.videoLevels ?? "auto" },
                    set: { controller.settings.videoLevels = $0 == "auto" ? nil : $0 })) {
                    Text(L("levels_auto")).tag("auto")
                    Text(L("levels_limited")).tag("limited")
                    Text(L("levels_full")).tag("full")
                }
                Text(L("color_tags_hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section(L("settings_luts")) {
                LabeledContent(L("luts_folder")) {
                    HStack {
                        Text("\(controller.availableLUTs.count)")
                            .foregroundStyle(.secondary)
                        Button(L("open_in_finder")) { controller.openLUTsInFinder() }
                        Button(L("clear_data"), role: .destructive) {
                            confirmClearLUTs = true
                        }
                        .disabled(controller.availableLUTs.isEmpty)
                    }
                }
                Text(L("luts_hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section(L("settings_output")) {
                Picker(L("external_display"), selection: Binding(
                    get: { controller.externalDisplayID },
                    set: { controller.externalDisplayID = $0 })) {
                    Text(L("external_off")).tag(CGDirectDisplayID?.none)
                    ForEach(controller.availableScreens) { screen in
                        Text(screen.name).tag(CGDirectDisplayID?.some(screen.id))
                    }
                }
                Picker(L("monitor_device"), selection: Binding(
                    get: { controller.settings.monitorDeviceID },
                    set: { controller.settings.monitorDeviceID = $0 })) {
                    Text(L("external_off")).tag(String?.none)
                    ForEach(controller.devices.filter { $0.id.hasPrefix("decklink:") }) { device in
                        Text(device.name).tag(String?.some(device.id))
                    }
                }
                Text(L("monitor_device_hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker(L("playback_output"), selection: Binding(
                    get: { controller.playbackOutputUID },
                    set: { controller.playbackOutputUID = $0 })) {
                    Text(L("system_default")).tag(String?.none)
                    ForEach(AudioOutputDevices.list()) { device in
                        Text(device.name).tag(String?.some(device.uid))
                    }
                }
                Text(L("record_channels_hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section(L("settings_detection")) {
                Picker(L("detection_mode"), selection: $controller.settings.detectionMode) {
                    Text(L("mode_auto")).tag(RecDetectionMode.auto)
                    Text(L("mode_timecode")).tag(RecDetectionMode.timecodeRun)
                    Text(L("mode_manual")).tag(RecDetectionMode.manual)
                }
                Stepper(L("start_debounce", controller.settings.startDebounceFrames),
                        value: $controller.settings.startDebounceFrames, in: 0...30)
                Stepper(L("stop_debounce", controller.settings.stopDebounceFrames),
                        value: $controller.settings.stopDebounceFrames, in: 0...60)
                Text(L("debounce_hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Stepper(L("pre_roll", controller.settings.preRollSecondsEffective),
                        value: Binding(
                            get: { controller.settings.preRollSecondsEffective },
                            set: { controller.settings.preRollSeconds = $0 }),
                        in: 0...3, step: 0.5)
                Text(L("pre_roll_hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(L("recrun_hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section(L("settings_hotkeys")) {
                ForEach(HotkeyAction.allCases) { action in
                    HStack {
                        Text(L(action.titleKey))
                        Spacer()
                        Button {
                            hotkeys.recordingAction =
                                (hotkeys.recordingAction == action) ? nil : action
                        } label: {
                            Text(hotkeys.recordingAction == action
                                 ? L("press_keys")
                                 : hotkeys.combo(for: action).display)
                                .frame(minWidth: 90)
                        }
                        .tint(hotkeys.recordingAction == action
                              ? controller.accentColor : nil)
                    }
                }
                Button(L("reset_hotkeys")) {
                    hotkeys.resetToDefaults()
                }
                .buttonStyle(.link)
            }
            Section {
                Button(L("reset_all"), role: .destructive) {
                    controller.resetAllSettings()
                    hotkeys.resetToDefaults()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(L("clear_luts_confirm"), isPresented: $confirmClearLUTs) {
            Button(L("clear_data"), role: .destructive) { controller.clearLUTs() }
            Button(L("cancel"), role: .cancel) {}
        }
        .scrollContentBackground(.hidden)
        .background(controller.appBackground)
        .frame(width: 500)
        .padding(.top, 28) // under the window buttons: title bar hidden
        .padding([.horizontal, .bottom])
        .background(controller.appBackground.ignoresSafeArea())
    }
}
