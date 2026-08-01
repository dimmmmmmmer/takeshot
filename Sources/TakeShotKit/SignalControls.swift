import CaptureCore
import SwiftUI

// The three controls that decide how the incoming signal is read.
//
// Each of them is offered in two places — the badge menus over the player, for
// the operator who is looking at the picture, and the Settings pane, for the
// one who is setting the rig up — and each had been written out twice. They are
// not decorative: the input mode and the RGB flag restart capture, and the
// detection mode is what decides whether a take starts at all. Two spellings of
// a control like that is two chances to fix only one of them.
//
// The style stays with the caller: the badge menus wear `.pickerStyle(.inline)`
// and hide their labels, Settings disables its rows while a take is rolling.
// Both are environment modifiers, so they reach the picker through the wrapper.

/// Force a DeckLink input mode, or let the board detect one.
struct InputModePicker: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        Picker(L("input_mode"), selection: Binding(
            get: { controller.settings.forcedInputMode ?? "auto" },
            set: { controller.settings.forcedInputMode =
                $0 == "auto" ? nil : $0 })) {
            Text(L("input_mode_auto")).tag("auto")
            ForEach(controller.selectedDeviceInputModes, id: \.self) { name in
                Text(name).tag(name)
            }
        }
    }
}

/// The RGB 4:4:4 override, which only means anything once a mode is forced —
/// on auto the board reports the sampling itself, and a switch that claims
/// otherwise is a lie about what is being captured.
struct ForcedInputRGBToggle: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        if controller.settings.forcedInputMode != nil {
            Toggle(L("input_mode_rgb"), isOn: Binding(
                get: { controller.settings.forcedInputRGB ?? false },
                set: { controller.settings.forcedInputRGB = $0 }))
        }
    }
}

/// What the source's code values mean on the wire — and, for the third option,
/// what the pipeline is allowed to throw away while reading them.
///
/// Three, not two. The first two are the settings this app has always had:
/// expand studio swing once, or pass a full-swing signal through. The third
/// exists because the expansion CLAMPS: a camera legally rides its blacks below
/// code 64 and its highlights above 940, and the normal reading destroys those
/// codes in the display buffer and in the recorded file both — the record
/// buffer is built from the expanded value, so what is clipped on the glass is
/// clipped in the deliverable. `limited_excursions` expands the camera's whole
/// legal swing instead, so nothing is lost; the picture is a hair flatter in
/// exchange. It is never selected automatically — the default does not change.
struct InputLevelsPicker: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        Picker(L("video_levels"), selection: Binding(
            get: {
                guard let value = controller.settings.videoLevels else {
                    return "auto"
                }
                return value == "off" ? "full" : value // legacy spelling
            },
            set: { controller.settings.videoLevels = $0 == "auto" ? nil : $0 })) {
            Text(L("levels_auto")).tag("auto")
            Text(L("levels_limited")).tag(InputLevels.limited.rawValue)
            Text(L("levels_excursions"))
                .tag(InputLevels.limitedPreservingExcursions.rawValue)
            Text(L("levels_full")).tag(InputLevels.full.rawValue)
        }
        .help(L("levels_hint"))
    }
}

/// What starts a take. The default is VANC-only on purpose: running timecode
/// alone is not evidence a camera is rolling (a Resolve playout feeding the
/// board runs timecode too), and it must never start a take.
struct DetectionModePicker: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        Picker(L("detection_mode"),
               selection: $controller.settings.detectionMode) {
            Text(L("mode_vanc")).tag(RecDetectionMode.vanc)
            Text(L("mode_auto")).tag(RecDetectionMode.auto)
            Text(L("mode_timecode")).tag(RecDetectionMode.timecodeRun)
            Text(L("mode_manual")).tag(RecDetectionMode.manual)
        }
    }
}
