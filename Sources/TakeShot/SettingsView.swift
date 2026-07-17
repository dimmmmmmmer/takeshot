import CaptureCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var controller: CaptureController
    @EnvironmentObject private var hotkeys: HotkeyManager

    var body: some View {
        Form {
            Section(L("settings_interface")) {
                Picker(L("language"), selection: Binding(
                    get: { controller.appLanguage },
                    set: { controller.appLanguage = $0 })) {
                    Text(L("lang_english")).tag(AppLanguage.english)
                    Text(L("lang_russian")).tag(AppLanguage.russian)
                    Text(L("lang_system")).tag(AppLanguage.system)
                }
            }
            Section(L("settings_recording")) {
                Picker(L("codec"), selection: $controller.settings.codec) {
                    ForEach(CaptureCodec.allCases) { codec in
                        Text(codec.rawValue).tag(codec)
                    }
                }
                HStack {
                    TextField(L("destination_folder"), text: $controller.settings.destinationPath)
                    Button {
                        chooseDestinationFolder()
                    } label: {
                        Image(systemName: "folder")
                    }
                    .help(L("choose_folder"))
                }
                TextField(L("project"), text: $controller.settings.projectName)
                TextField(L("camera"), text: $controller.settings.cameraLabel)
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
                        value: $controller.settings.startDebounceFrames, in: 1...30)
                Stepper(L("stop_debounce", controller.settings.stopDebounceFrames),
                        value: $controller.settings.stopDebounceFrames, in: 1...60)
                Stepper(L("pre_roll", controller.settings.preRollSecondsEffective),
                        value: Binding(
                            get: { controller.settings.preRollSecondsEffective },
                            set: { controller.settings.preRollSeconds = $0 }),
                        in: 0...3, step: 0.5)
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
        .frame(width: 480)
        .padding()
    }

    private func chooseDestinationFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath:
            (controller.settings.destinationPath as NSString).expandingTildeInPath)
        if panel.runModal() == .OK, let url = panel.url {
            controller.settings.destinationPath = url.path
        }
    }
}
