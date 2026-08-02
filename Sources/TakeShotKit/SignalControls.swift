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

/// What the source's code values mean on the wire.
///
/// Three options, and one of them is Limited — there were two studio-swing
/// entries for a while, and the one that survived is the one that expands the
/// camera's WHOLE legal swing. The other clamped: the record buffer is built
/// from the expanded value, so codes 4 and 1019 decoded to 0 and 1023 and the
/// excursions were destroyed in the deliverable, not just on the glass.
struct InputLevelsPicker: View {
    @EnvironmentObject private var controller: CaptureController

    /// Legacy stored spellings map onto the option that now means them, so an
    /// operator's saved choice selects a row rather than nothing (see
    /// `CaptureSettings.migrateToVersion2`, which rewrites the value itself).
    private var selection: String {
        switch controller.settings.videoLevels {
        case nil: return "auto"
        case "off": return InputLevels.full.rawValue
        case "limited_excursions": return InputLevels.limited.rawValue
        case let value?: return value
        }
    }

    var body: some View {
        Picker(L("video_levels"), selection: Binding(
            get: { selection },
            set: { controller.settings.videoLevels = $0 == "auto" ? nil : $0 })) {
            Text(L("levels_auto")).tag("auto")
            Text(L("levels_limited")).tag(InputLevels.limited.rawValue)
            Text(L("levels_full")).tag(InputLevels.full.rawValue)
        }
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
