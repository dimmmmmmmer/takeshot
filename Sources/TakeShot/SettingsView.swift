import CaptureCore
import SwiftUI

/// Editable frame-count row: type a number or use the stepper.
struct FrameCountField: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                TextField("", value: Binding(
                    get: { value },
                    set: { value = min(range.upperBound, max(range.lowerBound, $0)) }),
                    format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 56)
                Stepper("", value: $value, in: range)
                    .labelsHidden()
            }
        }
    }
}

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
                Picker(L("input_mode"), selection: Binding(
                    get: { controller.settings.forcedInputMode ?? "auto" },
                    set: { controller.settings.forcedInputMode = $0 == "auto" ? nil : $0 })) {
                    Text(L("input_mode_auto")).tag("auto")
                    ForEach(controller.selectedDeviceInputModes, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .disabled(controller.isRecording)
                if controller.settings.forcedInputMode != nil {
                    Toggle(L("input_mode_rgb"), isOn: Binding(
                        get: { controller.settings.forcedInputRGB ?? false },
                        set: { controller.settings.forcedInputRGB = $0 }))
                }
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
                Button(L("reset_interface"), role: .destructive) {
                    controller.resetInterface()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
            }
            Section(L("settings_recording")) {
                Picker(L("codec"), selection: $controller.settings.codec) {
                    ForEach(CaptureCodec.allCases) { codec in
                        Text(codec.rawValue).tag(codec)
                    }
                }
                Toggle(L("ten_bit_capture"), isOn: Binding(
                    get: { controller.settings.tenBitCapture ?? true },
                    set: { controller.settings.tenBitCapture = $0 }))
                TextField(L("project"), text: $controller.settings.projectName)
                HStack(spacing: 8) {
                    Text(L("backup_folder"))
                        .fixedSize()
                    Text(controller.settings.backupPath ?? L("assist_off"))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button(L("choose")) {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.canCreateDirectories = true
                        if panel.runModal() == .OK, let url = panel.url {
                            controller.settings.backupPath = url.path
                        }
                    }
                    if controller.settings.backupPath != nil {
                        Button(L("assist_off")) {
                            controller.settings.backupPath = nil
                        }
                    }
                }
                HStack(spacing: 8) {
                    Text(L("destination_folder"))
                        .fixedSize()
                    Text(controller.settings.destinationPath)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    Button(L("choose_folder")) {
                        controller.chooseDestinationFolder()
                    }
                    .fixedSize()
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
                Picker(L("video_levels"), selection: Binding(
                    get: {
                        let v = controller.settings.videoLevels
                        return v == nil ? "auto" : (v == "off" ? "full" : v!)
                    },
                    set: { controller.settings.videoLevels = $0 == "auto" ? nil : $0 })) {
                    Text(L("levels_auto")).tag("auto")
                    Text(L("levels_limited")).tag("limited")
                    Text(L("levels_full")).tag("full")
                }
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
                Picker(L("playback_output"), selection: Binding(
                    get: { controller.playbackOutputUID },
                    set: { controller.playbackOutputUID = $0 })) {
                    Text(L("system_default")).tag(String?.none)
                    ForEach(AudioOutputDevices.list()) { device in
                        Text(device.name).tag(String?.some(device.uid))
                    }
                }
            }
            Section(L("settings_detection")) {
                Picker(L("detection_mode"), selection: $controller.settings.detectionMode) {
                    Text(L("mode_vanc")).tag(RecDetectionMode.vanc)
                    Text(L("mode_auto")).tag(RecDetectionMode.auto)
                    Text(L("mode_timecode")).tag(RecDetectionMode.timecodeRun)
                    Text(L("mode_manual")).tag(RecDetectionMode.manual)
                }
                FrameCountField(label: L("start_frames"),
                                value: $controller.settings.startDebounceFrames,
                                range: 0...60)
                FrameCountField(label: L("stop_frames"),
                                value: $controller.settings.stopDebounceFrames,
                                range: 0...120)
                FrameCountField(label: L("pre_roll_frames"), value: Binding(
                    get: { controller.settings.preRollFramesEffective },
                    set: {
                        controller.settings.preRollFrames = $0
                        controller.settings.preRollSeconds = nil
                    }), range: 0...100)
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
                Button(L("reset_hotkeys"), role: .destructive) {
                    hotkeys.resetToDefaults()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
            }
            Section {
                Button(L("reset_all"), role: .destructive) {
                    controller.resetAllSettings()
                    hotkeys.resetToDefaults()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
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
        .padding(.top, 16) // under the window buttons: title bar hidden
        .padding([.horizontal, .bottom])
        .background(controller.appBackground.ignoresSafeArea())
    }
}
