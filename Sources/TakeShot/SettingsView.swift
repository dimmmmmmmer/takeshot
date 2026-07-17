import CaptureCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var controller: CaptureController
    @EnvironmentObject private var hotkeys: HotkeyManager

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
            }
            Section(L("settings_recording")) {
                Picker(L("codec"), selection: $controller.settings.codec) {
                    ForEach(CaptureCodec.allCases) { codec in
                        Text(codec.rawValue).tag(codec)
                    }
                }
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
            }
            Section(L("settings_naming")) {
                TextField(L("naming_template"), text: $controller.settings.namingTemplate)
                Text(L("placeholders", NamingEngine.placeholders.joined(separator: " ")))
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
                        .tint(hotkeys.recordingAction == action ? .accentColor : nil)
                    }
                }
                Button(L("reset_hotkeys")) {
                    hotkeys.resetToDefaults()
                }
                .buttonStyle(.link)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .padding()
    }
}
