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

extension SettingsView {
    /// Vendor naming presets (see NamingPreset.all; kept as an alias so both
    /// Settings and the footer menu read the same list).
    static var namingPresets: [NamingPreset] { NamingPreset.all }

    /// The width of the settings window. Every row is a localized label beside a
    /// control, so `ViewSettingsTests` measures the rows against this rather
    /// than trusting them to fit.
    static var width: CGFloat { 500 }
}

struct SettingsView: View {
    @EnvironmentObject private var controller: CaptureController
    @EnvironmentObject private var hotkeys: HotkeyManager
    @State private var confirmClearLUTs = false
    @State private var editingHotkeys = false

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
                // shared with the badge menu over the player — see
                // `SignalControls`; both restart capture
                InputModePicker()
                    .disabled(controller.isRecording)
                ForcedInputRGBToggle()
                // restarts capture, like the two above
                CaptureBitDepthPicker()
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
                MenuBarSettingsRow()
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
                TextField(L("project"), text: $controller.settings.projectName)
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
                // shared with the badge menu over the player — see
                // `SignalControls`
                InputLevelsPicker()
                // beside the levels picker on purpose: the two are the same
                // question one range apart — what the wire's codes mean
                HDRModePicker()
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
            }
            R3DSettingsSection()
            OutputSettingsSection()
            Section(L("settings_detection")) {
                DetectionModePicker()
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
            OffloadSettingsSection()
            RemoteSettingsSection()
            NDISettingsSection()
            Section(L("settings_hotkeys")) {
                // fifteen rows of label-plus-button used to live here and made
                // everything below them a scroll away; the list is a sheet now
                // (HotkeyEditorView), with its own search and conflict check
                LabeledContent(L("hotkey_bindings")) {
                    Button(L("hotkey_edit")) { editingHotkeys = true }
                }
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
        .sheet(isPresented: $editingHotkeys) {
            HotkeyEditorView(hotkeys: hotkeys)
                .environmentObject(controller)
                .environmentObject(hotkeys)
        }
        .scrollContentBackground(.hidden)
        .background(controller.appBackground)
        // A fixed width, deliberately: `minWidth` here hands the window the
        // Form's own ideal width (776pt, the same in every language — it is a
        // Form default, not a content measurement) and the settings window
        // balloons. The rows fit 500 in both languages; ViewSettingsTests
        // measures them so a longer translation fails a test instead of
        // silently truncating a label.
        .frame(width: Self.width)
        .padding(.top, 16) // under the window buttons: title bar hidden
        .padding([.horizontal, .bottom])
        .background(controller.appBackground.ignoresSafeArea())
        // clicking empty space clears focus from text fields — the same escape
        // hatch the main window has (ContentView); controls still take their
        // own clicks first
        .onTapGesture {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
        // Open with nothing focused: the project name is the first text field in
        // the Form, so AppKit handed it the keyboard and the first stray key
        // renamed the show. Tab order is untouched (and kept released across
        // reopens — see InitialFocusKeeper).
        .releasesInitialFocus()
    }
}
